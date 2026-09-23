#!/usr/bin/env bash
#
# Install the CSI snapshot stack on one or more Kind clusters.
#
# What it does:
#   1. Installs snapshot CRDs + snapshot controller (external-snapshotter)
#   2. Installs the CSI hostpath driver via the official deploy.sh
#   3. Creates the CSI StorageClass (csi-hostpath-sc)
#   4. Creates a VolumeSnapshotClass annotated for Kasten
#
# Usage:
#   scripts/bootstrap-clusters.sh k8s-source k8s-restore
#   scripts/bootstrap-clusters.sh            # defaults to CLUSTERS env or both
#
set -euo pipefail

# ---- config ---------------------------------------------------------------
# Informational version (external-snapshotter). The raw URLs use a branch.
SNAPSHOT_VERSION="${SNAPSHOT_VERSION:-v8.0.2}"
SNAPSHOTTER_BRANCH="${SNAPSHOTTER_BRANCH:-release-8.0}"

# csi-driver-host-path tag. `master` works but you can pin (e.g. v1.15.0).
CSI_DRIVER_VERSION="${CSI_DRIVER_VERSION:-master}"

# Names used for the StorageClass and VolumeSnapshotClass created below.
STORAGE_CLASS_NAME="${STORAGE_CLASS_NAME:-csi-hostpath-sc}"
SNAPSHOT_CLASS_NAME="${SNAPSHOT_CLASS_NAME:-kasten-snapshotclass}"

SNAPSHOTTER_RAW="https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAPSHOTTER_BRANCH}"

# ---- resolve cluster list -------------------------------------------------
if [ $# -gt 0 ]; then
  CLUSTERS=("$@")
elif [ -n "${CLUSTERS:-}" ]; then
  # shellcheck disable=SC2206
  CLUSTERS=(${CLUSTERS})
else
  CLUSTERS=(k8s-source k8s-restore)
fi

echo "Bootstrapping clusters: ${CLUSTERS[*]}"

# ---- clone csi-driver-host-path once --------------------------------------
CSI_TMP="$(mktemp -d)"
cleanup() { rm -rf "$CSI_TMP"; }
trap cleanup EXIT

echo ""
echo "-> cloning csi-driver-host-path (${CSI_DRIVER_VERSION})"
if ! git clone --depth 1 --branch "${CSI_DRIVER_VERSION}" \
      https://github.com/kubernetes-csi/csi-driver-host-path.git "$CSI_TMP" 2>/dev/null; then
  echo "WARN: tag '${CSI_DRIVER_VERSION}' not found — falling back to master"
  git clone --depth 1 \
    https://github.com/kubernetes-csi/csi-driver-host-path.git "$CSI_TMP"
fi

# Pick a deploy directory — prefer kubernetes-latest, else the highest 1.x
if [ -d "$CSI_TMP/deploy/kubernetes-latest" ]; then
  DEPLOY_DIR="$CSI_TMP/deploy/kubernetes-latest"
else
  DEPLOY_DIR="$(ls -d "$CSI_TMP"/deploy/kubernetes-1.* 2>/dev/null | sort -V | tail -1)"
fi

if [ -z "${DEPLOY_DIR:-}" ] || [ ! -d "$DEPLOY_DIR" ]; then
  echo "ERROR: no suitable deploy directory found under $CSI_TMP/deploy/"
  ls -la "$CSI_TMP/deploy/" 2>/dev/null || true
  exit 1
fi
echo "-> using deploy dir: $(basename "$DEPLOY_DIR")"

# ---- per-cluster install --------------------------------------------------
for cluster in "${CLUSTERS[@]}"; do
  ctx="kind-${cluster}"
  echo ""
  echo "=== ${ctx} ==="

  if ! kubectl config get-contexts "$ctx" >/dev/null 2>&1; then
    echo "ERROR: context '${ctx}' not found. Run 'make cluster' first."
    exit 1
  fi

  # 1. Snapshot CRDs -------------------------------------------------------
  echo "-> installing snapshot CRDs (${SNAPSHOT_VERSION})"
  kubectl --context "$ctx" apply -f \
    "${SNAPSHOTTER_RAW}/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml"
  kubectl --context "$ctx" apply -f \
    "${SNAPSHOTTER_RAW}/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml"
  kubectl --context "$ctx" apply -f \
    "${SNAPSHOTTER_RAW}/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml"

  # 2. Snapshot controller -------------------------------------------------
  echo "-> installing snapshot controller"
  kubectl --context "$ctx" apply -f \
    "${SNAPSHOTTER_RAW}/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml"
  kubectl --context "$ctx" apply -f \
    "${SNAPSHOTTER_RAW}/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml"

  # 3. CSI hostpath driver (official deploy.sh) ----------------------------
  echo "-> installing csi-hostpath-driver"
  old_ctx="$(kubectl config current-context)"
  kubectl config use-context "$ctx" >/dev/null
  ( cd "$DEPLOY_DIR" && ./deploy.sh )
  kubectl config use-context "$old_ctx" >/dev/null

  echo "-> waiting for csi-hostpath plugin pods"
  kubectl --context "$ctx" -n default wait \
    --for=condition=Ready pod \
    -l app.kubernetes.io/name=csi-hostpathplugin \
    --timeout=180s || true

  # 4. CSI StorageClass ----------------------------------------------------
  # The upstream deploy.sh doesn't always create this. Without a
  # CSI-capable StorageClass, PVCs land on Kind's default `standard`
  # (local-path) class, which doesn't support snapshots — and Kasten
  # backups will fail. Create it explicitly so both clusters have it.
  echo "-> ensuring StorageClass '${STORAGE_CLASS_NAME}'"
  kubectl --context "$ctx" apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${STORAGE_CLASS_NAME}
provisioner: hostpath.csi.k8s.io
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
EOF

  # 5. VolumeSnapshotClass annotated for Kasten ----------------------------
  echo "-> creating VolumeSnapshotClass '${SNAPSHOT_CLASS_NAME}'"
  kubectl --context "$ctx" apply -f - <<EOF
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: ${SNAPSHOT_CLASS_NAME}
  annotations:
    k10.kasten.io/is-snapshot-class: "true"
driver: hostpath.csi.k8s.io
deletionPolicy: Delete
EOF

  echo "-> ${ctx}: done"
done

echo ""
echo "Bootstrap complete."
echo "Verify with:"
echo "  kubectl --context kind-${CLUSTERS[0]} get volumesnapshotclass"
echo "  kubectl --context kind-${CLUSTERS[0]} get storageclass"
echo "  kubectl --context kind-${CLUSTERS[0]} -n default get pods -l app.kubernetes.io/name=csi-hostpathplugin"