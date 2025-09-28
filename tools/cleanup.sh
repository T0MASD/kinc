#!/bin/bash
set -euo pipefail

echo "🧹 kinc Rootless Cluster Cleanup"
echo "================================"

# Configuration: Cluster name
CLUSTER_NAME="${CLUSTER_NAME:-default}"
echo "🏷️  Cleaning up cluster: $CLUSTER_NAME"

echo "Stopping user services..."
systemctl --user stop kinc-${CLUSTER_NAME}-control-plane.service kinc-${CLUSTER_NAME}-var-data-volume.service kinc-${CLUSTER_NAME}-config-volume.service 2>/dev/null || true

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

echo "Removing container..."
podman rm -f kinc-${CLUSTER_NAME}-control-plane 2>/dev/null || true
echo "✅ Container removed"

echo "Removing volumes..."
podman volume rm kinc-${CLUSTER_NAME}-var-data kinc-${CLUSTER_NAME}-config 2>/dev/null || true
echo "✅ Volumes removed"

echo "Removing Quadlet files..."
rm -f ~/.config/containers/systemd/kinc-${CLUSTER_NAME}-*.*

# Clean up any system-level quadlet files if they exist
if sudo test -f /etc/containers/systemd/kinc-control-plane.container; then
    echo "⚠️  Found system-level quadlet files, cleaning up..."
    sudo systemctl stop kinc-control-plane.service kinc-var-data-volume.service 2>/dev/null || true
    sudo podman rm -f kinc-control-plane 2>/dev/null || true
    sudo rm -f /etc/containers/systemd/kinc-*.*
    sudo systemctl daemon-reload
    echo "✅ System-level quadlet files cleaned up"
fi
echo "✅ Quadlet files removed"

echo "Reloading user systemd..."
systemctl --user daemon-reload
systemctl --user reset-failed 2>/dev/null || true
echo "✅ User systemd reloaded"

echo
echo "🎯 Complete cleanup commands (for reference):"
echo "  systemctl --user stop kinc-${CLUSTER_NAME}-control-plane.service kinc-${CLUSTER_NAME}-var-data-volume.service kinc-${CLUSTER_NAME}-config-volume.service"
echo "  podman rm -f kinc-${CLUSTER_NAME}-control-plane"
echo "  podman volume rm kinc-${CLUSTER_NAME}-var-data kinc-${CLUSTER_NAME}-config"
echo "  rm -f ~/.config/containers/systemd/kinc-${CLUSTER_NAME}-*.*"
echo "  systemctl --user daemon-reload"
echo
echo "✅ Rootless cleanup complete!"
