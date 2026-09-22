#!/usr/bin/env bash
#
# Install the CSI snapshot stack on one or more Kind clusters.
#
# What it does:
#   1. Installs snapshot CRDs + snapshot controller
#   2. Installs the CSI hostpath driver (snapshot-capable StorageClass)
#   3. Creates a VolumeSnapshotClass annotated for Kasten
#
# Usage:
#   scripts/bootstrap-cluster.sh arg1-cluster arg2-cluster
#   scripts/bootstrap-cluster.sh            # defaults to CLUSTERS env or both
#
set -euo pipefail

# ---- config ---------------------------------------------------------------
SNAPSHOT_VERSION="${SNAPSHOT_VERSION:-v8.0.1}"
CSI_DRIVER_VERSION="${CSI_DRIVER_VERSION:-v1.11.0}"
SNAPSHOT_CLASS_NAME="${SNAPSHOT_CLASS_NAME:-kasten-snapshotclass}"

# Args: cluster names (without "kind-" prefix). Fall back to CLUSTERS env.
if [ $# -gt 0 ]; then
  CLUSTERS=("$@")
elif [ -n "${CLUSTERS:-}" ]; then
  # shellcheck disable=SC2206
  CLUSTERS=(${CLUSTERS})
else
  CLUSTERS=(k8s-source k8s-restore)
fi

echo "Bootstrapping clusters: ${CLUSTERS[*]}"

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
    "https://github.com/kubernetes-csi/external-snapshotter/releases/download/${SNAPSHOT_VERSION}/snapshot.storage.k8s.io_volumesnapshotclasses.yaml"
  kubectl --context "$ctx" apply -f \
    "https://github.com/kubernetes-csi/external-snapshotter/releases/download/${SNAPSHOT_VERSION}/snapshot.storage.k8s.io_volumesnapshotcontents.yaml"
  kubectl --context "$ctx" apply -f \
    "https://github.com/kubernetes-csi/external-snapshotter/releases/download/${SNAPSHOT_VERSION}/snapshot.storage.k8s.io_volumesnapshots.yaml"

  # 2. Snapshot controller -------------------------------------------------
  echo "-> installing snapshot controller"
  kubectl --context "$ctx" apply -f \
    "https://github.com/kubernetes-csi/external-snapshotter/releases/download/${SNAPSHOT_VERSION}/rbac-snapshot-controller.yaml"
  kubectl --context "$ctx" apply -f \
    "https://github.com/kubernetes-csi/external-snapshotter/releases/download/${SNAPSHOT_VERSION}/setup-snapshot-controller.yaml"

  # 3. CSI hostpath driver -------------------------------------------------
  echo "-> installing csi-hostpath-driver (${CSI_DRIVER_VERSION})"
  kubectl --context "$ctx" apply -k \
    "github.com/kubernetes-csi/csi-driver-host-path/deploy/kubernetes-1.31/hostpath?ref=${CSI_DRIVER_VERSION}" \
    || {
      echo "WARN: csi-hostpath kustomize apply failed — trying the latest deploy dir"
      kubectl --context "$ctx" apply -k \
        "github.com/kubernetes-csi/csi-driver-host-path/deploy/kubernetes-latest/hostpath?ref=${CSI_DRIVER_VERSION}"
    }

  echo "-> waiting for csi-hostpath plugin pods"
  kubectl --context "$ctx" -n kube-system wait \
    --for=condition=Ready pod \
    -l app.kubernetes.io/name=csi-hostpathplugin \
    --timeout=180s || true

  # 4. VolumeSnapshotClass annotated for Kasten ----------------------------
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