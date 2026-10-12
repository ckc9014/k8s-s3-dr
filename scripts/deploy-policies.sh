#!/usr/bin/env bash
#
# Create DR policies on the source + restore clusters.
#
# SOURCE cluster:
#   - Backup policy (backup + export to S3)
#
# RESTORE cluster:
#   - Import policy (migration token patched in if source token exists)
#
# Assumes Kasten is installed and the Location Profile is valid.
# See deploy-kasten.sh for that part.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$PROJECT_ROOT"

# ---- config ---------------------------------------------------------------
K10_NAMESPACE="kasten-io"
APP_NAMESPACE="${APP_NAMESPACE:-mongodb}"
K10_BACKUP_POLICY="manifests/kasten/backup-policy.yaml"
K10_IMPORT_POLICY="manifests/kasten/import-policy.yaml"

# ---- resolve cluster list -------------------------------------------------
if [ $# -gt 0 ]; then
  CLUSTERS=("$@")
elif [ -n "${CLUSTERS:-}" ]; then
  CLUSTERS=(${CLUSTERS})
else
  CLUSTERS=(k8s-source k8s-restore)
fi

SOURCE_CLUSTER="${CLUSTERS[0]}"
RESTORE_CLUSTER="${CLUSTERS[1]:-}"

echo "Applying DR policies to: ${CLUSTERS[*]}"
echo "  source:  ${SOURCE_CLUSTER}"
echo "  restore: ${RESTORE_CLUSTER:-<none>}"

# ===========================================================================
# Per-cluster policy install
# ===========================================================================
for cluster in "${CLUSTERS[@]}"; do
  ctx="kind-${cluster}"
  echo ""
  echo "=== ${ctx} ==="

  # SOURCE cluster: Backup Policy
  if [ "$cluster" = "$SOURCE_CLUSTER" ]; then
    echo "-> applying backup policy (source only)"
    kubectl --context "$ctx" apply -f "$K10_BACKUP_POLICY"
    echo "   migration token is created after the first successful export"
  fi

  # RESTORE cluster: Import Policy + token handoff
  if [ -n "$RESTORE_CLUSTER" ] && [ "$cluster" = "$RESTORE_CLUSTER" ]; then
    echo "-> applying import policy (restore only) — placeholder"
    kubectl --context "$ctx" apply -f "$K10_IMPORT_POLICY"

    SOURCE_CTX="kind-${SOURCE_CLUSTER}"
    echo "-> fetching migration token from ${SOURCE_CTX}"
    SOURCE_TOKEN=""
    for i in $(seq 1 24); do
      SOURCE_TOKEN=$(kubectl --context "$SOURCE_CTX" -n "$K10_NAMESPACE" \
        get policy backup-labeled \
        -o jsonpath='{.spec.actions[?(@.action=="export")].exportParameters.receiveString}' \
        2>/dev/null || true)
      if [ -n "$SOURCE_TOKEN" ]; then
        echo "   token available after ${i} attempt(s) (length ${#SOURCE_TOKEN})"
        break
      fi
      echo "   waiting for token... (${i}/24)"
      sleep 5
    done

    if [ -z "$SOURCE_TOKEN" ]; then
      echo "   WARN: source policy has no token yet."
      echo "         Run 'make backup' then 'make import-restore-points'."
    else
      echo "-> patching import policy with fresh token"
      kubectl --context "$ctx" -n "$K10_NAMESPACE" patch policy import-labeled \
        --type merge \
        -p "{\"spec\":{\"actions\":[{\"action\":\"import\",\"importParameters\":{\"profile\":{\"name\":\"s3-backup-profile\",\"namespace\":\"kasten-io\"},\"receiveString\":\"${SOURCE_TOKEN}\"}}]}}" \
        >/dev/null

      echo "-> waiting for import policy to validate"
      for i in $(seq 1 24); do
        status=$(kubectl --context "$ctx" -n "$K10_NAMESPACE" get policy import-labeled \
          -o jsonpath='{.status.validation}' 2>/dev/null || true)
        if [ "$status" = "Success" ]; then
          echo "   import policy Success after ${i} attempt(s)"
          break
        fi
        if [ "$i" -eq 24 ]; then
          echo "   WARN: import policy is '${status}' after 24 attempts"
        fi
        sleep 5
      done
    fi
  fi

  echo "-> ${ctx}: done"
done

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "Policies applied:"
echo "  source:  backup-labeled"
if [ -n "$RESTORE_CLUSTER" ]; then
  echo "  restore: import-labeled"
fi