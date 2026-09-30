#!/bin/bash
set -euo pipefail

echo "🧹 kinc Rootless Cluster Cleanup"
echo "================================"

# Configuration: Cluster name
CLUSTER_NAME="${CLUSTER_NAME:-default}"
echo "🏷️  Cleaning up cluster: $CLUSTER_NAME"

STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/kinc/${CLUSTER_NAME}"

# Every node of this cluster, control plane and workers alike. Worker names are
# discovered from the quadlets on disk rather than from a count, so a cleanup
# after a partial deploy still finds them.
NODES=(kinc-${CLUSTER_NAME}-control-plane)
for f in ~/.config/containers/systemd/kinc-${CLUSTER_NAME}-w*.container; do
    [ -e "$f" ] || continue
    NODES+=("$(basename "$f" .container)")
done
echo "🧩 Nodes: ${NODES[*]}"

echo "Stopping user services..."
for node in "${NODES[@]}"; do
    systemctl --user stop ${node}.service ${node}-var-data-volume.service \
        ${node}-etc-kubernetes-volume.service 2>/dev/null || true
done
systemctl --user stop kinc-${CLUSTER_NAME}-var-data-volume.service kinc-${CLUSTER_NAME}-config-volume.service \
    kinc-${CLUSTER_NAME}-etc-kubernetes-volume.service 2>/dev/null || true
# The network outlives its containers, so it is stopped after them.
systemctl --user stop kinc-${CLUSTER_NAME}-network.service 2>/dev/null || true

# Wait for services to actually stop
echo "Waiting for services to stop..."
for i in {1..30}; do
    if ! systemctl --user is-active kinc-${CLUSTER_NAME}-control-plane.service >/dev/null 2>&1; then
        break
    fi
    echo "  Waiting for kinc-${CLUSTER_NAME}-control-plane.service to stop... ($i/30)"
    sleep 1
done

# Force kill any remaining pasta processes
pkill -f "pasta.*6443" 2>/dev/null || true
echo "✅ Services stopped"

echo "Removing containers..."
for node in "${NODES[@]}"; do
    podman rm -f "$node" 2>/dev/null || true
done
echo "✅ Containers removed"

echo "Removing volumes..."
for node in "${NODES[@]}"; do
    podman volume rm "${node}-var-data" "${node}-etc-kubernetes" 2>/dev/null || true
done
podman volume rm kinc-${CLUSTER_NAME}-var-data kinc-${CLUSTER_NAME}-config \
    kinc-${CLUSTER_NAME}-etc-kubernetes 2>/dev/null || true

# The cluster's PersistentVolumes. Removed with the cluster, like its other
# volumes - export it first if the data matters:
#   podman volume export kinc-${CLUSTER_NAME}-storage > storage.tar
podman volume rm kinc-${CLUSTER_NAME}-storage 2>/dev/null || true
echo "✅ Volumes removed"

echo "Removing cluster network..."
podman network rm -f kinc-${CLUSTER_NAME} 2>/dev/null || true
echo "✅ Network removed"

# The CA and the rendered join configs. They are the cluster's, so they go with
# it: a redeploy under the same name mints a new CA and renders new configs.
# Each node's image store lives under here too, and its layer directories are
# owned by the container's mapped UIDs - an unprivileged rm cannot touch them
# and stops at "Permission denied", leaving the store behind. Removing it from
# inside the user namespace that owns it is the only thing that works.
#
# A store left behind is not cosmetic: the next deploy mounts it again, and a
# half-removed store is one whose layers.json no longer describes what is on
# disk. So this asserts the directory is gone rather than hoping.
echo "Removing cluster state..."
if [ -d "${STATE_DIR}" ]; then
    podman unshare rm -rf "${STATE_DIR}"
fi
if [ -e "${STATE_DIR}" ]; then
    echo "❌ ${STATE_DIR} survived removal - a later deploy would reuse it"
    exit 1
fi
echo "✅ Cluster state removed"

echo "Removing Quadlet files..."
rm -f ~/.config/containers/systemd/kinc-${CLUSTER_NAME}-*.*
echo "✅ Quadlet files removed"

echo "Reloading user systemd..."
systemctl --user daemon-reload
systemctl --user reset-failed 2>/dev/null || true
echo "✅ User systemd reloaded"

echo
echo "🎯 Complete cleanup commands (for reference):"
echo "  systemctl --user stop kinc-${CLUSTER_NAME}-control-plane.service kinc-${CLUSTER_NAME}-var-data-volume.service kinc-${CLUSTER_NAME}-config-volume.service"
echo "  podman rm -f kinc-${CLUSTER_NAME}-control-plane"
echo "  podman volume rm kinc-${CLUSTER_NAME}-var-data kinc-${CLUSTER_NAME}-config kinc-${CLUSTER_NAME}-etc-kubernetes"
echo "  rm -f ~/.config/containers/systemd/kinc-${CLUSTER_NAME}-*.*"
echo "  systemctl --user daemon-reload"
echo
echo "✅ Rootless cleanup complete!"
