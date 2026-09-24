#!/usr/bin/env bash
#
# Copy the migration token from the source backup policy into the
# restore cluster's import policy, then wait for it to validate.
#
set -euo pipefail

SOURCE_CTX="${SOURCE_CTX:-kind-k8s-source}"
RESTORE_CTX="${RESTORE_CTX:-kind-k8s-restore}"
K10_NAMESPACE="kasten-io"
SOURCE_POLICY="${SOURCE_POLICY:-mongodb-backup}"
IMPORT_POLICY="${IMPORT_POLICY:-mongodb-import}"

echo "-> waiting for migration token on ${SOURCE_CTX}/${SOURCE_POLICY}"
SOURCE_TOKEN=""
for i in $(seq 1 60); do
  SOURCE_TOKEN=$(kubectl --context "$SOURCE_CTX" -n "$K10_NAMESPACE" \
    get policy "$SOURCE_POLICY" \
    -o jsonpath='{.spec.actions[?(@.action=="export")].exportParameters.receiveString}' \
    2>/dev/null || true)
  if [ -n "$SOURCE_TOKEN" ]; then
    echo "   token available after ${i} attempt(s) (length ${#SOURCE_TOKEN})"
    break
  fi
  echo "   waiting for token... (${i}/60)"
  sleep 5
done

if [ -z "$SOURCE_TOKEN" ]; then
  echo "ERROR: source policy still has no migration token after 5 min."
  echo "       Check: kubectl --context ${SOURCE_CTX} -n ${K10_NAMESPACE} get policy ${SOURCE_POLICY} -o yaml | tail -40"
  exit 1
fi

echo "-> patching ${RESTORE_CTX}/${IMPORT_POLICY}"
kubectl --context "$RESTORE_CTX" -n "$K10_NAMESPACE" patch policy "$IMPORT_POLICY" \
  --type merge \
  -p "{\"spec\":{\"actions\":[{\"action\":\"import\",\"importParameters\":{\"profile\":{\"name\":\"s3-backup-profile\",\"namespace\":\"kasten-io\"},\"receiveString\":\"${SOURCE_TOKEN}\"}}]}}" \
  >/dev/null

echo "-> waiting for import policy to validate"
for i in $(seq 1 24); do
  status=$(kubectl --context "$RESTORE_CTX" -n "$K10_NAMESPACE" \
    get policy "$IMPORT_POLICY" -o jsonpath='{.status.validation}' 2>/dev/null || true)
  if [ "$status" = "Success" ]; then
    echo "   import policy Success after ${i} attempt(s)"
    exit 0
  fi
  echo "   waiting... (${i}/24)"
  sleep 5
done

echo "ERROR: import policy did not validate within 2 minutes"
exit 1