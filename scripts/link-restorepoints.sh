#!/usr/bin/env bash
#
# Link imported RestorePointContents into RestorePoint objects in the
# application namespace. Kasten 9.x imports create cluster-scoped
# RestorePointContents but not the namespace-scoped RestorePoints that
# RestoreActions need to target.
#
set -euo pipefail

RESTORE_CTX="${RESTORE_CTX:-kind-k8s-restore}"
APP_NAMESPACE="${APP_NAMESPACE:-mongodb}"

echo "Linking imported RestorePointContents → RestorePoints in ${APP_NAMESPACE}..."

RPC_LIST=$(kubectl --context "$RESTORE_CTX" get restorepointcontents -o name 2>/dev/null || true)

if [ -z "$RPC_LIST" ]; then
  echo "No RestorePointContents found on ${RESTORE_CTX}."
  echo "Have you run 'make import-restore-points'?"
  exit 1
fi

echo "$RPC_LIST" | while read -r rpc; do
  name="${rpc#restorepointcontent.apps.kio.kasten.io/}"
  echo "  linking: ${name}"
  kubectl --context "$RESTORE_CTX" create -f - <<EOF 2>/dev/null || true
apiVersion: apps.kio.kasten.io/v1alpha1
kind: RestorePoint
metadata:
  name: ${name}
  namespace: ${APP_NAMESPACE}
spec:
  restorePointContentRef:
    name: ${name}
EOF
done

echo "Waiting for RestorePoints to become visible..."
for i in $(seq 1 24); do
  count=$(kubectl --context "$RESTORE_CTX" -n "$APP_NAMESPACE" get restorepoints \
    --no-headers 2>/dev/null | wc -l)
  if [ "$count" -gt 0 ]; then
    echo "✅ ${count} restore points available in ${APP_NAMESPACE}"
    exit 0
  fi
  echo "  waiting... (${i}/24)"
  sleep 5
done

echo "❌ Timed out waiting for restore points"
exit 1