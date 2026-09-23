#!/usr/bin/env bash
#
# Validate the most recent Kasten backup/restore and the restored MongoDB data.
#
# Checks:
#   1. Latest BackupAction on source cluster is Complete
#   2. Latest RestoreAction on restore cluster is Complete
#   3. mongodb-0 pod is Ready in the restore cluster
#   4. Document count in restored MongoDB matches EXPECTED_DOCS
#
# Usage:
#   scripts/validate-backup.sh mongodb 1000
#
set -euo pipefail

APP_NAMESPACE="${1:-mongodb}"
EXPECTED_DOCS="${2:-1000}"

SOURCE_CTX="${SOURCE_CTX:-kind-k8s-source}"
RESTORE_CTX="${RESTORE_CTX:-kind-k8s-restore}"
K10_NAMESPACE="kasten-io"
MONGO_COLLECTION="${MONGO_COLLECTION:-users}"
MONGO_DB="${MONGO_DB:-testdb}"

fail() { echo "❌ $*" >&2; exit 1; }
ok()   { echo "✅ $*"; }

# ---- helpers --------------------------------------------------------------
latest_cr() {
  # $1 = context, $2 = namespace, $3 = resource kind (plural)
  kubectl --context "$1" -n "$2" get "$3" \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || true
}

cr_state() {
  # $1 = context, $2 = namespace, $3 = resource kind, $4 = name
  # Kasten 9.x uses .status.state (not .status.phase)
  kubectl --context "$1" -n "$2" get "$3" "$4" \
    -o jsonpath='{.status.state}' 2>/dev/null || true
}

# ---- sanity: contexts exist -----------------------------------------------
kubectl config get-contexts "$SOURCE_CTX"  >/dev/null 2>&1 || fail "context '$SOURCE_CTX' not found"
kubectl config get-contexts "$RESTORE_CTX" >/dev/null 2>&1 || fail "context '$RESTORE_CTX' not found"

echo "SOURCE_CTX:  ${SOURCE_CTX}"
echo "RESTORE_CTX: ${RESTORE_CTX}"
echo "NAMESPACE:   ${APP_NAMESPACE}"
echo ""

# ---- 1. Backup on source --------------------------------------------------
echo "==> Checking backup on ${SOURCE_CTX} (namespace ${APP_NAMESPACE})"
BACKUP=$(latest_cr "$SOURCE_CTX" "$APP_NAMESPACE" backupactions)
[ -n "$BACKUP" ] || fail "no BackupAction found on source"

BACKUP_STATE=$(cr_state "$SOURCE_CTX" "$APP_NAMESPACE" backupactions "$BACKUP")
echo "    BackupAction ${BACKUP}: ${BACKUP_STATE}"
[ "$BACKUP_STATE" = "Complete" ] || fail "backup state is '${BACKUP_STATE}', expected 'Complete'"
ok "backup complete"

# ---- 2. Restore on restore cluster ----------------------------------------
echo "==> Checking restore on ${RESTORE_CTX}"
RESTORE=$(latest_cr "$RESTORE_CTX" "$APP_NAMESPACE" restoreactions)
[ -n "$RESTORE" ] || fail "no RestoreAction found on restore cluster"

RESTORE_STATE=$(cr_state "$RESTORE_CTX" "$APP_NAMESPACE" restoreactions "$RESTORE")
echo "    RestoreAction ${RESTORE}: ${RESTORE_STATE}"
[ "$RESTORE_STATE" = "Complete" ] || fail "restore state is '${RESTORE_STATE}', expected 'Complete'"
ok "restore complete"

# ---- 3. Mongo pod ready ---------------------------------------------------
echo "==> Waiting for MongoDB pod in ${RESTORE_CTX}"
kubectl --context "$RESTORE_CTX" -n "$APP_NAMESPACE" wait \
  --for=condition=Ready pod/mongodb-0 --timeout=180s \
  || fail "mongodb-0 not Ready in ${RESTORE_CTX}"
ok "mongodb-0 ready"

# ---- 4. Document count ----------------------------------------------------
echo "==> Counting documents in ${MONGO_DB}.${MONGO_COLLECTION}"
PASSWORD=$(kubectl --context "$RESTORE_CTX" -n "$APP_NAMESPACE" \
  get secret mongodb-root -o jsonpath='{.data.password}' | base64 -d)

ACTUAL=$(kubectl --context "$RESTORE_CTX" -n "$APP_NAMESPACE" exec mongodb-0 -- \
  mongosh --quiet \
    --username root \
    --password "$PASSWORD" \
    --authenticationDatabase admin \
    --eval "db.getSiblingDB('${MONGO_DB}').${MONGO_COLLECTION}.countDocuments()" 2>/dev/null | tail -1)

echo "    expected: ${EXPECTED_DOCS}, actual: ${ACTUAL}"

[ "$ACTUAL" = "$EXPECTED_DOCS" ] \
  || fail "document count mismatch: expected ${EXPECTED_DOCS}, got ${ACTUAL}"
ok "document count matches"

echo ""
echo "✅ Validation passed (backup + restore + ${ACTUAL} docs)"