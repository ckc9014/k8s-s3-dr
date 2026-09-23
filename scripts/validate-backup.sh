#!/usr/bin/env bash
#
# Validate the most recent Kasten backup/restore and the restored MongoDB data.
#
# Two checks:
#   1. Kasten CRs on source + restore clusters are Complete
#   2. MongoDB doc count in the restore cluster matches EXPECTED_DOCS
#
# Usage:
#   scripts/validate-backup.sh mongodb 1000
#
set -euo pipefail

APP_NAMESPACE="${1:-mongodb}"
EXPECTED_DOCS="${2:-1000}"

SOURCE_CTX="${SOURCE_CTX:-kind-dr-lab-source}"
RESTORE_CTX="${RESTORE_CTX:-kind-dr-lab-restore}"
K10_NAMESPACE="kasten-io"
MONGO_COLLECTION="${MONGO_COLLECTION:-users}"
MONGO_DB="${MONGO_DB:-testdb}"

fail() { echo "❌ $*" >&2; exit 1; }
ok()   { echo "✅ $*"; }

# ---- helpers --------------------------------------------------------------
latest_cr() {
  # $1 = context, $2 = resource kind (e.g. backupactions)
  kubectl --context "$1" -n "$K10_NAMESPACE" get "$2" \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || true
}

cr_phase() {
  # $1 = context, $2 = resource kind, $3 = name
  kubectl --context "$1" -n "$K10_NAMESPACE" get "$2" "$3" \
    -o jsonpath='{.status.state}' 2>/dev/null || true
}

# ---- 1. Backup on source --------------------------------------------------
echo "==> Checking backup on ${SOURCE_CTX}"
BACKUP=$(latest_cr "$SOURCE_CTX" backupactions)
[ -n "$BACKUP" ] || fail "no BackupAction found on source"

BACKUP_PHASE=$(cr_phase "$SOURCE_CTX" backupactions "$BACKUP")
echo "    BackupAction ${BACKUP}: ${BACKUP_PHASE}"
[ "$BACKUP_PHASE" = "Complete" ] || fail "backup phase is '${BACKUP_PHASE}', expected 'Complete'"
ok "backup complete"

# ---- 2. Restore on restore cluster ---------------------------------------
echo "==> Checking restore on ${RESTORE_CTX}"
RESTORE=$(latest_cr "$RESTORE_CTX" restoreactions)
[ -n "$RESTORE" ] || fail "no RestoreAction found on restore cluster"

RESTORE_PHASE=$(cr_phase "$RESTORE_CTX" restoreactions "$RESTORE")
echo "    RestoreAction ${RESTORE}: ${RESTORE_PHASE}"
[ "$RESTORE_PHASE" = "Complete" ] || fail "restore phase is '${RESTORE_PHASE}', expected 'Complete'"
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