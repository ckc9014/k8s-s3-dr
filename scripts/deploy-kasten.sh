#!/usr/bin/env bash
#
# Install Kasten K10 on both clusters and wire up S3 (backup + import).
#
# SOURCE cluster  (CLUSTERS[0]):
#   - K10 install
#   - Location Profile
#   - Backup Policy  (backup + export to S3)
#
# RESTORE cluster (CLUSTERS[1]):
#   - K10 install
#   - Location Profile
#   - Import Policy + triggered initial import
#   - Link imported RestorePointContents → RestorePoints in the app namespace
#   - Bare app namespace with Kasten discovery label
#
# Reads:
#   .tf-output.json   (bucket name + region)
#   .env              (K10_AWS_* keys)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$PROJECT_ROOT"

# ---- config ---------------------------------------------------------------
TF_OUTPUT="${PROJECT_ROOT}/.tf-output.json"
K10_NAMESPACE="kasten-io"
APP_NAMESPACE="${APP_NAMESPACE:-mongodb}"
K10_VALUES="manifests/kasten/k10-values.yaml"
K10_PROFILE="manifests/kasten/location-profile.yaml"
K10_BACKUP_POLICY="manifests/kasten/backup-policy.yaml"
K10_IMPORT_POLICY="manifests/kasten/import-policy.yaml"
K10_IMPORT_RUN_ACTION="manifests/kasten/import-run-action.yaml"

if [ ! -f "$TF_OUTPUT" ]; then
  echo "ERROR: ${TF_OUTPUT} not found. Run 'make terraform-apply' first."
  exit 1
fi

# shellcheck disable=SC1091
[ -f .env ] && set -a && source .env && set +a

BUCKET_NAME=$(jq -r '.bucket_name.value' "$TF_OUTPUT")
export BUCKET_NAME
AWS_REGION="${AWS_REGION:-$(jq -r '.bucket_region.value' "$TF_OUTPUT")}"
export AWS_REGION
export K10_AWS_ACCESS_KEY_ID="${K10_AWS_ACCESS_KEY_ID:-}"
export K10_AWS_SECRET_ACCESS_KEY="${K10_AWS_SECRET_ACCESS_KEY:-}"

: "${BUCKET_NAME:?BUCKET_NAME could not be resolved from .tf-output.json}"
: "${AWS_REGION:?AWS_REGION could not be resolved}"
: "${K10_AWS_ACCESS_KEY_ID:?K10_AWS_ACCESS_KEY_ID must be set in .env}"
: "${K10_AWS_SECRET_ACCESS_KEY:?K10_AWS_SECRET_ACCESS_KEY must be set in .env}"

# ---- resolve cluster list -------------------------------------------------
if [ $# -gt 0 ]; then
  CLUSTERS=("$@")
elif [ -n "${CLUSTERS:-}" ]; then
  # shellcheck disable=SC2206
  CLUSTERS=(${CLUSTERS})
else
  CLUSTERS=(k8s-source k8s-restore)
fi

SOURCE_CLUSTER="${CLUSTERS[0]}"
RESTORE_CLUSTER="${CLUSTERS[1]:-}"

echo "Deploying Kasten K10 to: ${CLUSTERS[*]}"
echo "  bucket:  ${BUCKET_NAME}"
echo "  region:  ${AWS_REGION}"
echo "  source:  ${SOURCE_CLUSTER}"
echo "  restore: ${RESTORE_CLUSTER:-<none>}"

# ---- pre-flight: verify contexts, create namespaces on ALL clusters -------
echo ""
echo "==> Pre-flight: verifying contexts + creating namespaces"
for cluster in "${CLUSTERS[@]}"; do
  ctx="kind-${cluster}"
  if ! kubectl config get-contexts "$ctx" >/dev/null 2>&1; then
    echo "ERROR: context '${ctx}' not found. Run 'make cluster' first."
    exit 1
  fi

  echo "-> ${ctx}: ensuring namespace ${K10_NAMESPACE}"
  kubectl --context "$ctx" create namespace "$K10_NAMESPACE" \
    --dry-run=client -o yaml | kubectl --context "$ctx" apply -f -
done

# Restore cluster needs the app namespace + Kasten discovery label.
if [ -n "$RESTORE_CLUSTER" ]; then
  ctx="kind-${RESTORE_CLUSTER}"
  echo "-> ${ctx}: ensuring app namespace ${APP_NAMESPACE} with Kasten label"
  kubectl --context "$ctx" create namespace "$APP_NAMESPACE" \
    --dry-run=client -o yaml | kubectl --context "$ctx" apply -f -
  kubectl --context "$ctx" label ns "$APP_NAMESPACE" \
    k10.kasten.io/backup=true --overwrite
fi

# ---- per-cluster install --------------------------------------------------
for cluster in "${CLUSTERS[@]}"; do
  ctx="kind-${cluster}"
  echo ""
  echo "=== ${ctx} ==="

  # 1. Helm repo -----------------------------------------------------------
  echo "-> adding kasten helm repo"
  helm repo add kasten https://charts.kasten.io/ >/dev/null 2>&1 || true
  helm repo update kasten >/dev/null

  # 2. Helm install / upgrade ---------------------------------------------
  # IMPORTANT: helm installs the Kasten CRDs. We must NOT wait for CRDs
  # before this step — they don't exist until helm runs.
  echo "-> installing k10 (version ${K10_VERSION:-latest})"
  if helm status k10 -n "$K10_NAMESPACE" --kube-context "$ctx" >/dev/null 2>&1; then
    echo "   k10 already installed — upgrading"
    helm upgrade k10 kasten/k10 \
      --kube-context "$ctx" \
      --namespace "$K10_NAMESPACE" \
      ${K10_VERSION:+--version "$K10_VERSION"} \
      -f "$K10_VALUES"
  else
    echo "   fresh install"
    helm install k10 kasten/k10 \
      --kube-context "$ctx" \
      --namespace "$K10_NAMESPACE" \
      ${K10_VERSION:+--version "$K10_VERSION"} \
      -f "$K10_VALUES"
  fi

  # 3. Wait for the Profile CRD to be established -------------------------
  # Now that helm has installed them, wait for the CRD to register with the
  # API server before trying to create any Kasten custom resources.
  echo "-> waiting for Profile CRD to be established"
  if ! kubectl --context "$ctx" wait --for=condition=established --timeout=180s \
         crd/profiles.config.kio.kasten.io; then
    echo "ERROR: Profile CRD not established on ${ctx} after helm install."
    echo "       Check helm release: helm status k10 -n ${K10_NAMESPACE} --kube-context ${ctx}"
    exit 1
  fi

  # 4. Wait for gateway ----------------------------------------------------
  echo "-> waiting for k10 gateway"
  kubectl --context "$ctx" -n "$K10_NAMESPACE" rollout status \
    deploy/gateway --timeout=300s

  # 5. Location Profile ----------------------------------------------------
  echo "-> applying Location Profile (bucket=${BUCKET_NAME}, region=${AWS_REGION})"
  envsubst < "$K10_PROFILE" | kubectl --context "$ctx" apply -f -

  # 6. SOURCE cluster: Backup Policy ---------------------------------------
  if [ "$cluster" = "$SOURCE_CLUSTER" ]; then
    echo "-> applying backup policy (source only)"
    kubectl --context "$ctx" apply -f "$K10_BACKUP_POLICY"
  fi

  # 7. RESTORE cluster: Import Policy + import + link restore points -------
  if [ -n "$RESTORE_CLUSTER" ] && [ "$cluster" = "$RESTORE_CLUSTER" ]; then
    echo "-> applying import policy (restore only)"
    kubectl --context "$ctx" apply -f "$K10_IMPORT_POLICY"

    echo "-> triggering initial import of restore points from S3"
    kubectl --context "$ctx" create -f "$K10_IMPORT_RUN_ACTION"

    # Wait for RestorePointContents to appear (up to 5 min)
    echo "-> waiting for imported RestorePointContents"
    for i in $(seq 1 60); do
      RPC_COUNT=$(kubectl --context "$ctx" get restorepointcontents \
        --no-headers 2>/dev/null | wc -l)
      if [ "$RPC_COUNT" -gt 0 ]; then
        echo "   found ${RPC_COUNT} imported contents"
        break
      fi
      if [ "$i" -eq 60 ]; then
        echo "   WARN: no RestorePointContents after 5 min (OK if no backup exists yet)"
        continue
      fi
      sleep 5
    done

    # Link each RestorePointContent → RestorePoint in the app namespace.
    # Kasten 9.x doesn't create namespace-scoped RestorePoints on import.
    echo "-> linking RestorePointContents to RestorePoints in ${APP_NAMESPACE}"
    RPC_LIST=$(kubectl --context "$ctx" get restorepointcontents -o name 2>/dev/null || true)
    if [ -n "$RPC_LIST" ]; then
      echo "$RPC_LIST" | while read -r rpc; do
        name="${rpc#restorepointcontent.apps.kio.kasten.io/}"
        kubectl --context "$ctx" create -f - <<RPEOF 2>/dev/null || true
apiVersion: apps.kio.kasten.io/v1alpha1
kind: RestorePoint
metadata:
  name: ${name}
  namespace: ${APP_NAMESPACE}
spec:
  restorePointContentRef:
    name: ${name}
RPEOF
        echo "   linked: ${name}"
      done
      echo "   done linking"
    else
      echo "   no RestorePointContents to link"
    fi
  fi

  echo "-> ${ctx}: done"
done

echo ""
echo "Kasten deployed."
echo "Verify:"
echo "  kubectl --context kind-${SOURCE_CLUSTER}  -n ${K10_NAMESPACE} get policies"
if [ -n "$RESTORE_CLUSTER" ]; then
  echo "  kubectl --context kind-${RESTORE_CLUSTER} -n ${K10_NAMESPACE} get policies"
  echo "  kubectl --context kind-${RESTORE_CLUSTER} -n ${APP_NAMESPACE} get restorepoints"
fi