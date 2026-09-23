#!/usr/bin/env bash
#
# Install Kasten K10 on both clusters and wire up the S3 Location Profile.
#
# Reads:
#   .tf-output.json             (from terraform apply)
#   .env                        (AWS_REGION, K10_VERSION, K10_AWS_* keys)
#   manifests/kasten/crds/      (vendored Kasten CRDs — optional but recommended)
#
# Usage:
#   scripts/deploy-kasten.sh k8s-source k8s-restore
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$PROJECT_ROOT"

# ---- config ---------------------------------------------------------------
TF_OUTPUT="${PROJECT_ROOT}/.tf-output.json"
K10_NAMESPACE="kasten-io"
K10_VALUES="manifests/kasten/k10-values.yaml"
K10_PROFILE="manifests/kasten/location-profile.yaml"
K10_BACKUP_POLICY="manifests/kasten/backup-policy.yaml"
K10_CRD_DIR="manifests/kasten/crds"

if [ ! -f "$TF_OUTPUT" ]; then
  echo "ERROR: ${TF_OUTPUT} not found. Run 'make terraform-apply' first."
  exit 1
fi

# Load .env for K10 creds and region
# shellcheck disable=SC1091
[ -f .env ] && set -a && source .env && set +a

# Resolve values from Terraform output + .env
BUCKET_NAME=$(jq -r '.bucket_name.value' "$TF_OUTPUT")
export BUCKET_NAME

AWS_REGION="${AWS_REGION:-$(jq -r '.bucket_region.value' "$TF_OUTPUT")}"
export AWS_REGION

export K10_AWS_ACCESS_KEY_ID="${K10_AWS_ACCESS_KEY_ID:-}"
export K10_AWS_SECRET_ACCESS_KEY="${K10_AWS_SECRET_ACCESS_KEY:-}"

# Fail fast if required values are missing
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

echo "Deploying Kasten K10 to: ${CLUSTERS[*]}"
echo "  bucket:  ${BUCKET_NAME}"
echo "  region:  ${AWS_REGION}"

# ---- pre-flight: verify contexts + create namespaces on ALL clusters ------
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

# ---- per-cluster install --------------------------------------------------
for cluster in "${CLUSTERS[@]}"; do
  ctx="kind-${cluster}"
  echo ""
  echo "=== ${ctx} ==="

  # 1. Helm repo -----------------------------------------------------------
  echo "-> adding kasten helm repo"
  helm repo add kasten https://charts.kasten.io/ >/dev/null 2>&1 || true
  helm repo update kasten >/dev/null

  # 2. Ensure Kasten CRDs are installed and established --------------------
   if [ -d "$K10_CRD_DIR" ] && [ -n "$(ls -A "$K10_CRD_DIR" 2>/dev/null)" ]; then
    echo "-> applying vendored Kasten CRDs from ${K10_CRD_DIR}"
    kubectl --context "$ctx" apply --server-side --force-conflicts -f "$K10_CRD_DIR"
  else
    echo "-> no vendored CRDs found — relying on helm to install them"
    echo "   (if this fails, run: make vendor-crds)"
  fi

  echo "-> waiting for Profile CRD to be established"
  if ! kubectl --context "$ctx" wait --for condition=established --timeout=120s \
         crd/profiles.config.kio.kasten.io; then
    echo "ERROR: Profile CRD not established on ${ctx}"
    echo "       The chart may not have installed CRDs. Try:"
    echo "         helm uninstall k10 -n ${K10_NAMESPACE} --kube-context ${ctx}"
    echo "         make deploy-kasten"
    exit 1
  fi

  # 3. Helm install / upgrade ---------------------------------------------
  echo "-> installing k10 (version ${K10_VERSION:-latest})"
  if helm status k10 -n "$K10_NAMESPACE" --kube-context "$ctx" >/dev/null 2>&1; then
    echo "   k10 already installed — upgrading"
    helm upgrade k10 kasten/k10 \
      --kube-context "$ctx" \
      --namespace "$K10_NAMESPACE" \
      ${K10_VERSION:+--version "$K10_VERSION"} \
      -f "$K10_VALUES"
  else
    helm install k10 kasten/k10 \
      --kube-context "$ctx" \
      --namespace "$K10_NAMESPACE" \
      ${K10_VERSION:+--version "$K10_VERSION"} \
      -f "$K10_VALUES"
  fi

  # 4. Wait for the gateway to come up -------------------------------------
  echo "-> waiting for k10 gateway"
  kubectl --context "$ctx" -n "$K10_NAMESPACE" rollout status \
    deploy/gateway --timeout=300s

  # 5. Location Profile + S3 secret (templated with envsubst) --------------
  echo "-> applying Location Profile (bucket=${BUCKET_NAME}, region=${AWS_REGION})"
  envsubst < "$K10_PROFILE" | kubectl --context "$ctx" apply -f -

  # 6. Backup Policy — source cluster only ---------------------------------
  # Only the source cluster needs a backup policy. The restore cluster just
  # needs the profile so it can discover restore points from S3.
  if [ "$cluster" = "${CLUSTERS[0]}" ]; then
    echo "-> applying backup policy (source cluster only)"
    kubectl --context "$ctx" apply -f "$K10_BACKUP_POLICY"
  fi

  echo "-> ${ctx}: done"
done

echo ""
echo "Kasten deployed. Check with:"
echo "  kubectl --context kind-${CLUSTERS[0]} -n kasten-io get pods"
echo "  kubectl --context kind-${CLUSTERS[0]} -n kasten-io get profiles"
echo "  kubectl --context kind-${CLUSTERS[0]} -n kasten-io get policies"