#!/usr/bin/env bash
#
# Trigger a Kasten restore on the restore cluster.
#
# Discovers the latest available RestorePoint on cluster B (which
# imported the S3 profile), then applies a RestoreAction.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$PROJECT_ROOT"

RESTORE_CTX="${RESTORE_CTX:-kind-dr-lab-restore}"
K10_NAMESPACE="kasten-io"
APP_NAMESPACE="${APP_NAMESPACE:-mongodb}"

echo "Discovering restore points on ${RESTORE_CTX}..."
RP=$(kubectl --context "$RESTORE_CTX" -n "$K10_NAMESPACE" get restorepoints \
  --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || true)

if [ -z "$RP" ]; then
  echo "❌ No restore points found on ${RESTORE_CTX}."
  echo "   Have you run 'make backup' and waited for the export to complete?"
  exit 1
fi

echo "Using restore point: ${RP}"

kubectl --context "$RESTORE_CTX" apply -f - <<EOF
apiVersion: apps.kio.kasten.io/v1alpha1
kind: RestoreAction
metadata:
  name: restore-mongodb
  namespace: ${K10_NAMESPACE}
spec:
  subject:
    name: ${APP_NAMESPACE}
    namespace: ${APP_NAMESPACE}
  restorePoint:
    name: ${RP}
    namespace: ${K10_NAMESPACE}
  targetNamespace: ${APP_NAMESPACE}
EOF

echo "Waiting for RestoreAction to complete..."
for i in $(seq 1 120); do
  phase=$(kubectl --context "$RESTORE_CTX" -n "$K10_NAMESPACE" \
    get restoreaction restore-mongodb -o jsonpath='{.status.phase}' 2>/dev/null || true)
  echo "  RestoreAction: ${phase:-Pending}"
  case "$phase" in
    Complete) echo "✅ Restore complete"; exit 0 ;;
    Failed|Aborted) echo "❌ Restore $phase"; exit 1 ;;
  esac
  sleep 5
done

echo "❌ Timed out waiting for restore"
exit 1