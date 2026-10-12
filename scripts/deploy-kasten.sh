#!/usr/bin/env bash
#
# Install Kasten K10 on both clusters and configure S3 access.
#
# SOURCE cluster  (CLUSTERS[0]):
#   - K10 install
#   - S3 secret + Location Profile
#
# RESTORE cluster (CLUSTERS[1]):
#   - K10 install
#   - S3 secret + Location Profile
#   - Bare app namespace with Kasten discovery label
#
# Does NOT create policies. See deploy-policies.sh for that.
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
K10_S3_SECRET="manifests/kasten/s3-secret.yaml"

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

# ===========================================================================
# Pre-flight: verify contexts, create namespaces
# ===========================================================================
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

if [ -n "$RESTORE_CLUSTER" ]; then
  ctx="kind-${RESTORE_CLUSTER}"
  echo "-> ${ctx}: ensuring app namespace ${APP_NAMESPACE} with Kasten label"
  kubectl --context "$ctx" create namespace "$APP_NAMESPACE" \
    --dry-run=client -o yaml | kubectl --context "$ctx" apply -f -
  kubectl --context "$ctx" label ns "$APP_NAMESPACE" \
    k10.kasten.io/backup=true --overwrite
fi

# ===========================================================================
# Helper: wait for a Kasten APIService to become Available
# ===========================================================================
wait_for_apiservice() {
  local ctx="$1"
  local name="$2"
  local attempts="${3:-60}"

  echo "-> waiting for APIService ${name} to become Available"
  for i in $(seq 1 "$attempts"); do
    state=$(kubectl --context "$ctx" get apiservice "$name" \
      -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}' \
      2>/dev/null || true)
    if echo "$state" | grep -q 'Available=True'; then
      echo "   APIService available after ${i} attempt(s)"
      return 0
    fi
    if [ "$i" -eq "$attempts" ]; then
      echo "ERROR: APIService ${name} not Available on ${ctx}"
      kubectl --context "$ctx" get apiservices | grep kasten
      return 1
    fi
    sleep 5
  done
}

# ===========================================================================
# Helper: wait for a Kasten CRD to exist and be established
# ===========================================================================
wait_for_crd() {
  local ctx="$1"
  local crd_name="$2"
  local attempts="${3:-60}"

  echo "-> waiting for CRD ${crd_name} to be registered"
  for i in $(seq 1 "$attempts"); do
    if kubectl --context "$ctx" get crd "$crd_name" >/dev/null 2>&1; then
      echo "   CRD registered after ${i} attempt(s)"
      break
    fi
    if [ "$i" -eq "$attempts" ]; then
      echo "ERROR: CRD ${crd_name} not found on ${ctx}"
      return 1
    fi
    sleep 5
  done

  echo "-> waiting for CRD ${crd_name} to be established"
  kubectl --context "$ctx" wait --for=condition=established --timeout=120s \
    "crd/${crd_name}"
}

# ===========================================================================
# Per-cluster Kasten install
# ===========================================================================
for cluster in "${CLUSTERS[@]}"; do
  ctx="kind-${cluster}"
  echo ""
  echo "=== ${ctx} ==="

  # 1. Helm repo
  echo "-> adding kasten helm repo"
  helm repo add kasten https://charts.kasten.io/ >/dev/null 2>&1 || true
  helm repo update kasten >/dev/null

  # 2. Helm install / upgrade
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

  # 3. Wait for CRDs and APIServices
  wait_for_crd "$ctx" "profiles.config.kio.kasten.io" 180
  wait_for_crd "$ctx" "policies.config.kio.kasten.io" 180
  wait_for_apiservice "$ctx" "v1alpha1.actions.kio.kasten.io"
  wait_for_apiservice "$ctx" "v1alpha1.apps.kio.kasten.io"

  # 4. Wait for Kasten controllers
  echo "-> waiting for gateway"
  kubectl --context "$ctx" -n "$K10_NAMESPACE" rollout status \
    deploy/gateway --timeout=300s

  echo "-> waiting for aggregatedapis-svc"
  kubectl --context "$ctx" -n "$K10_NAMESPACE" rollout status \
    deploy/aggregatedapis-svc --timeout=300s

  echo "-> waiting for catalog-svc"
  kubectl --context "$ctx" -n "$K10_NAMESPACE" rollout status \
    deploy/catalog-svc --timeout=600s || {
      echo "   rollout slow — checking pod directly"
      kubectl --context "$ctx" -n "$K10_NAMESPACE" wait \
        --for=condition=Ready pod -l app=catalog-svc --timeout=300s
  }

  echo "-> waiting for controllermanager-svc"
  kubectl --context "$ctx" -n "$K10_NAMESPACE" rollout status \
    deploy/controllermanager-svc --timeout=300s

  # 5. S3 Secret + Location Profile
  echo "-> applying S3 credentials secret"
  envsubst < "$K10_S3_SECRET" | kubectl --context "$ctx" apply -f -

  echo "-> waiting for secret to appear in-cluster"
  for i in $(seq 1 12); do
    if kubectl --context "$ctx" -n "$K10_NAMESPACE" get secret k10-s3-creds >/dev/null 2>&1; then
      echo "   secret visible after ${i} attempt(s)"
      break
    fi
    sleep 5
  done
  sleep 5

  echo "-> applying Location Profile (bucket=${BUCKET_NAME}, region=${AWS_REGION})"
  envsubst < "$K10_PROFILE" | kubectl --context "$ctx" apply -f -

  echo "-> waiting for profile to validate"
  last_hash=""
  for i in $(seq 1 30); do
    status=$(kubectl --context "$ctx" -n "$K10_NAMESPACE" get profile s3-backup-profile \
      -o jsonpath='{.status.validation}' 2>/dev/null || true)
    hash=$(kubectl --context "$ctx" -n "$K10_NAMESPACE" get profile s3-backup-profile \
      -o jsonpath='{.status.hash}' 2>/dev/null || true)

    if [ "$status" = "Success" ]; then
      echo "   profile Success after ${i} attempt(s)"
      break
    fi

    if [ "$status" = "Failed" ] && [ "$hash" = "$last_hash" ]; then
      echo "   profile failing with same hash (${hash}) — restarting controller"
      kubectl --context "$ctx" -n "$K10_NAMESPACE" rollout restart deploy/controllermanager-svc
      kubectl --context "$ctx" -n "$K10_NAMESPACE" rollout status deploy/controllermanager-svc --timeout=180s
      sleep 30
      last_hash=""
      continue
    fi
    last_hash="$hash"

    if [ "$i" -eq 30 ]; then
      echo "   WARN: profile is '${status}' (hash=${hash}) after 30 attempts"
      kubectl --context "$ctx" -n "$K10_NAMESPACE" get profile s3-backup-profile
    fi
    sleep 5
  done

  echo "-> ${ctx}: done"
done

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "Kasten deployed. No policies created."
echo "Verify:"
echo "  kubectl --context kind-${SOURCE_CLUSTER} -n ${K10_NAMESPACE} get profile s3-backup-profile"
if [ -n "$RESTORE_CLUSTER" ]; then
  echo "  kubectl --context kind-${RESTORE_CLUSTER} -n ${K10_NAMESPACE} get profile s3-backup-profile"
fi
echo ""
echo "Next: apply policies with 'make deploy-policies', or create them in the Kasten UI."