#!/usr/bin/env bash
#
# Install Kasten K10 on both clusters and wire up S3 (backup + import).
#
# SOURCE cluster  (CLUSTERS[0]):
#   - K10 install
#   - Location Profile
#   - Backup Policy  (backup + export to S3, generates migration token)
#
# RESTORE cluster (CLUSTERS[1]):
#   - K10 install
#   - Location Profile
#   - Import Policy (with migration token from source)
#   - Triggered initial import
#   - Link imported RestorePointContents → RestorePoints in the app namespace
#   - Bare app namespace with Kasten discovery label
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

# Restore cluster needs the app namespace + Kasten discovery label
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

  # 1. Helm repo -----------------------------------------------------------
  echo "-> adding kasten helm repo"
  helm repo add kasten https://charts.kasten.io/ >/dev/null 2>&1 || true
  helm repo update kasten >/dev/null

  # 2. Helm install / upgrade ---------------------------------------------
  # CRITICAL ORDER: helm install creates the CRDs. Do NOT wait for CRDs
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

  # 3. Wait for CRDs and APIServices --------------------------------------
  wait_for_crd "$ctx" "profiles.config.kio.kasten.io"
  wait_for_crd "$ctx" "policies.config.kio.kasten.io"
  wait_for_crd "$ctx" "restorepoints.apps.kio.kasten.io"
  wait_for_apiservice "$ctx" "v1alpha1.actions.kio.kasten.io"

  # 4. Wait for Kasten controllers to be Ready ----------------------------
  # These are the services the profile/policy/import code paths depend on.
  echo "-> waiting for gateway"
  kubectl --context "$ctx" -n "$K10_NAMESPACE" rollout status \
    deploy/gateway --timeout=300s

  echo "-> waiting for aggregatedapis-svc"
  kubectl --context "$ctx" -n "$K10_NAMESPACE" rollout status \
    deploy/aggregatedapis-svc --timeout=300s

  echo "-> waiting for catalog-svc"
  kubectl --context "$ctx" -n "$K10_NAMESPACE" rollout status \
    deploy/catalog-svc --timeout=300s

  echo "-> waiting for controllermanager-svc"
  kubectl --context "$ctx" -n "$K10_NAMESPACE" rollout status \
    deploy/controllermanager-svc --timeout=300s

  # 5. Location Profile ----------------------------------------------------
  echo "-> applying Location Profile (bucket=${BUCKET_NAME}, region=${AWS_REGION})"
  envsubst < "$K10_PROFILE" | kubectl --context "$ctx" apply -f -

  # Wait for the profile to actually become Success
  echo "-> waiting for profile to validate"
  for i in $(seq 1 30); do
    status=$(kubectl --context "$ctx" -n "$K10_NAMESPACE" get profile s3-backup-profile \
      -o jsonpath='{.status.validation}' 2>/dev/null || true)
    if [ "$status" = "Success" ]; then
      echo "   profile Success after ${i} attempt(s)"
      break
    fi
    if [ "$i" -eq 30 ]; then
      echo "   WARN: profile is '${status}' after 30 attempts"
      kubectl --context "$ctx" -n "$K10_NAMESPACE" get profile s3-backup-profile
    fi
    sleep 5
  done

  # 6. SOURCE cluster: Backup Policy ---------------------------------------
  if [ "$cluster" = "$SOURCE_CLUSTER" ]; then
    echo "-> applying backup policy (source only)"
    kubectl --context "$ctx" apply -f "$K10_BACKUP_POLICY"

    # The backup policy's export action creates a migration token in its
    # spec once the policy reconciles. Give it time, but don't block on it —
    # the token also requires a successful export to be generated.
    echo "-> noting: migration token is created after the first successful export"
  fi

  # 7. RESTORE cluster: Import Policy + import + link restore points -------
  if [ -n "$RESTORE_CLUSTER" ] && [ "$cluster" = "$RESTORE_CLUSTER" ]; then
    echo "-> applying import policy (restore only) — placeholder, token added next"
    kubectl --context "$ctx" apply -f "$K10_IMPORT_POLICY"

    # Fetch the migration token from the SOURCE policy.
    # NOTE: In Kasten 9.x, the token lives in .spec.actions[].exportParameters.receiveString,
    # NOT in .status.receiveString.
    SOURCE_CTX="kind-${SOURCE_CLUSTER}"
    echo "-> fetching migration token from ${SOURCE_CTX}"
    SOURCE_TOKEN=""
    for i in $(seq 1 24); do
      SOURCE_TOKEN=$(kubectl --context "$SOURCE_CTX" -n "$K10_NAMESPACE" \
        get policy mongodb-backup \
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
      echo "         Run 'make backup' on the source cluster to generate it,"
      echo "         then re-apply the import policy:"
      echo "           SOURCE_TOKEN=\$(kubectl --context ${SOURCE_CTX} -n ${K10_NAMESPACE} get policy mongodb-backup -o jsonpath='{.spec.actions[?(@.action==\"export\")].exportParameters.receiveString}')"
      echo "           kubectl --context ${ctx} -n ${K10_NAMESPACE} patch policy mongodb-import --type merge -p \"{\\\"spec\\\":{\\\"actions\\\":[{\\\"action\\\":\\\"import\\\",\\\"importParameters\\\":{\\\"profile\\\":{\\\"name\\\":\\\"s3-backup-profile\\\",\\\"namespace\\\":\\\"kasten-io\\\"},\\\"receiveString\\\":\\\"\${SOURCE_TOKEN}\\\"}}]}}\""
    else
      echo "-> patching import policy with fresh token"
      kubectl --context "$ctx" -n "$K10_NAMESPACE" patch policy mongodb-import \
        --type merge \
        -p "{\"spec\":{\"actions\":[{\"action\":\"import\",\"importParameters\":{\"profile\":{\"name\":\"s3-backup-profile\",\"namespace\":\"kasten-io\"},\"receiveString\":\"${SOURCE_TOKEN}\"}}]}}" \
        >/dev/null

      # Wait for the import policy to validate
      echo "-> waiting for import policy to validate"
      for i in $(seq 1 24); do
        status=$(kubectl --context "$ctx" -n "$K10_NAMESPACE" get policy mongodb-import \
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

      echo "-> triggering initial import of restore points from S3"
      kubectl --context "$ctx" create -f "$K10_IMPORT_RUN_ACTION"
    fi

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
        echo "   WARN: no RestorePointContents after 5 min"
        echo "         (this is OK if you haven't run a backup yet)"
        break
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
      echo "   no RestorePointContents to link yet"
    fi
  fi

  echo "-> ${ctx}: done"
done

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "Kasten deployed."
echo "Verify:"
echo "  kubectl --context kind-${SOURCE_CLUSTER}  -n ${K10_NAMESPACE} get policies"
echo "  kubectl --context kind-${SOURCE_CLUSTER}  -n ${K10_NAMESPACE} get profile s3-backup-profile"
if [ -n "$RESTORE_CLUSTER" ]; then
  echo "  kubectl --context kind-${RESTORE_CLUSTER} -n ${K10_NAMESPACE} get policies"
  echo "  kubectl --context kind-${RESTORE_CLUSTER} -n ${K10_NAMESPACE} get profile s3-backup-profile"
  echo "  kubectl --context kind-${RESTORE_CLUSTER} -n ${APP_NAMESPACE} get restorepoints"
fi