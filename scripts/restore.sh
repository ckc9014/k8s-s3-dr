#!/usr/bin/env bash
#
# Trigger a Kasten restore on the restore cluster.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$PROJECT_ROOT"

# ---- config ---------------------------------------------------------------
RESTORE_CTX="${RESTORE_CTX:-kind-k8s-restore}"
APP_NAMESPACE="${APP_NAMESPACE:-mongodb}"

echo "Restore context: ${RESTORE_CTX}"
echo "App namespace:   ${APP_NAMESPACE}"
echo ""

# ---- sanity check ----------------------------------------------------------
if ! kubectl config get-contexts "$RESTORE_CTX" >/dev/null 2>&1; then
  echo "❌ Context '${RESTORE_CTX}' not found."
  exit 1
fi

# ---- find latest restore point --------------------------------------------
echo "Discovering restore points on ${RESTORE_CTX} in namespace ${APP_NAMESPACE}..."

RP=$(kubectl --context "$RESTORE_CTX" -n "$APP_NAMESPACE" get restorepoints \
  --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || true)

if [ -z "$RP" ]; then
  echo "❌ No restore points found on ${RESTORE_CTX} in ${APP_NAMESPACE}."
  echo "   Run 'make import-restore-points' first."
  exit 1
fi

echo "Latest restore point: ${RP}"

# ---- delete prior RestoreAction -------------------------------------------
if kubectl --context "$RESTORE_CTX" -n "$APP_NAMESPACE" \
     get restoreaction restore-mongodb >/dev/null 2>&1; then
  echo "-> removing previous RestoreAction"
  kubectl --context "$RESTORE_CTX" -n "$APP_NAMESPACE" \
    delete restoreaction restore-mongodb --wait=true
fi

# ---- create RestoreAction (subject = RestorePoint, per 9.x docs) ----------
echo "-> applying RestoreAction"
kubectl --context "$RESTORE_CTX" apply -f - <<EOF
apiVersion: actions.kio.kasten.io/v1alpha1
kind: RestoreAction
metadata:
  name: restore-mongodb
  namespace: ${APP_NAMESPACE}
spec:
  subject:
    kind: RestorePoint
    name: ${RP}
    namespace: ${APP_NAMESPACE}
  targetNamespace: ${APP_NAMESPACE}
  overwriteExisting: true
EOF

# ---- wait for completion ---------------------------------------------------
echo ""
echo "Waiting for RestoreAction to complete..."
for i in $(seq 1 120); do
  phase=$(kubectl --context "$RESTORE_CTX" -n "$APP_NAMESPACE" \
    get restoreaction restore-mongodb \
    -o jsonpath='{.status.state}' 2>/dev/null || true)
  echo "  RestoreAction: ${phase:-Pending}"
  case "$phase" in
    Complete) echo "✅ Restore complete"; exit 0 ;;
    Failed|Aborted)
      echo "❌ Restore ${phase}"
      kubectl --context "$RESTORE_CTX" -n "$APP_NAMESPACE" \
        describe restoreaction restore-mongodb | tail -30
      exit 1
      ;;
  esac
  sleep 5
done

echo "❌ Timed out waiting for restore"
kubectl --context "$RESTORE_CTX" -n "$APP_NAMESPACE" \
  describe restoreaction restore-mongodb | tail -30
exit 1