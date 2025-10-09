#!/bin/bash
set -euo pipefail

echo "🚀 kinc Rootless Quadlet Deployment"
echo "==================================="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

# Configuration: Cluster name and port management
CLUSTER_NAME="${CLUSTER_NAME:-default}"
FORCE_PORT="${FORCE_PORT:-}"  # Allow manual port override

# Image configuration - local development only
IMAGE_NAME="localhost/kinc/node:v1.33.5-${CLUSTER_NAME}"

echo "📁 Working directory: $SCRIPT_DIR"
echo "🏷️  Cluster name: $CLUSTER_NAME"
echo "🏷️  Using image: $IMAGE_NAME"

# Port allocation function - dynamic allocation based on environment inspection
get_cluster_port() {
    local cluster_name=$1
    local base_port=6443
    
    if [[ "$cluster_name" == "default" ]]; then
        echo $base_port
        return
    fi
    
    # Inspect existing kinc containers to find used ports
    local existing_ports=$(podman ps --filter "name=kinc-*" --format "{{.Ports}}" | \
                          grep -o '127\.0\.0\.1:[0-9]*' | \
                          cut -d: -f2 | \
                          sort -n)
    
    # Find next available port starting from 6444
    local next_port=6444
    for port in $existing_ports; do
        if [[ $port -ge $next_port ]]; then
            next_port=$((port + 1))
        fi
    done
    
    echo $next_port
}

# CIDR allocation functions - mapped from port last 2 digits
get_cluster_pod_subnet() {
    local port=$1
    
    # Extract last 2 digits from port (6443 -> 43, 6444 -> 44, etc.)
    local subnet_id=${port: -2}
    echo "10.244.${subnet_id}.0/24"
}

get_cluster_service_subnet() {
    local port=$1
    
    # Extract last 2 digits from port (6443 -> 43, 6444 -> 44, etc.)
    local subnet_id=${port: -2}
    echo "10.${subnet_id}.0.0/16"
}

# Port allocation
if [[ -n "$FORCE_PORT" ]]; then
    CLUSTER_PORT="$FORCE_PORT"
    echo "🔧 Using forced port: $CLUSTER_PORT"
else
    CLUSTER_PORT=$(get_cluster_port "$CLUSTER_NAME")
    echo "🔄 Using port: $CLUSTER_PORT (dynamically allocated)"
fi

# CIDR allocation based on port
CLUSTER_POD_SUBNET=$(get_cluster_pod_subnet "$CLUSTER_PORT")
CLUSTER_SERVICE_SUBNET=$(get_cluster_service_subnet "$CLUSTER_PORT")

echo "🌐 API Server will be available at: https://127.0.0.1:${CLUSTER_PORT}"
echo "🔗 Pod subnet: $CLUSTER_POD_SUBNET"
echo "🔗 Service subnet: $CLUSTER_SERVICE_SUBNET"

# Check for conflicts with existing clusters
if systemctl --user is-active kinc-${CLUSTER_NAME}-control-plane.service >/dev/null 2>&1; then
    echo "⚠️  Cluster '${CLUSTER_NAME}' is already running"
    echo "   Use 'CLUSTER_NAME=${CLUSTER_NAME} ./tools/cleanup.sh' to stop it first"
    echo "   Or choose a different cluster name for concurrent deployment"
    exit 1
fi

# Clean up any leftover artifacts from previous failed deployments
echo
echo "🧹 Step 1: Cleaning up any leftover artifacts"
rm -f ~/.config/containers/systemd/kinc-${CLUSTER_NAME}-*.*
systemctl --user daemon-reload
systemctl --user reset-failed 2>/dev/null || true
echo "✅ Ready for deployment"

# Step 2: Install Quadlet files with cluster-specific names
echo
echo "📦 Step 2: Installing Quadlet files"
mkdir -p ~/.config/containers/systemd/

# Copy and customize volume files
sed "s/VolumeName=kinc-var-data/VolumeName=kinc-${CLUSTER_NAME}-var-data/g" \
    runtime/quadlet/kinc-var-data.volume > ~/.config/containers/systemd/kinc-${CLUSTER_NAME}-var-data.volume

sed "s/VolumeName=kinc-config/VolumeName=kinc-${CLUSTER_NAME}-config/g" \
    runtime/quadlet/kinc-config.volume > ~/.config/containers/systemd/kinc-${CLUSTER_NAME}-config.volume

# Copy and customize container file
sed -e "s/ContainerName=kinc-control-plane/ContainerName=kinc-${CLUSTER_NAME}-control-plane/g" \
    -e "s/HostName=kinc-control-plane/HostName=kinc-${CLUSTER_NAME}-control-plane/g" \
    -e "s/Volume=kinc-var-data:/Volume=kinc-${CLUSTER_NAME}-var-data:/g" \
    -e "s/Volume=kinc-config:/Volume=kinc-${CLUSTER_NAME}-config:/g" \
    -e "s/kinc-var-data-volume.service/kinc-${CLUSTER_NAME}-var-data-volume.service/g" \
    -e "s/kinc-config-volume.service/kinc-${CLUSTER_NAME}-config-volume.service/g" \
    -e "s/PublishPort=127.0.0.1:6443:6443\/tcp/PublishPort=127.0.0.1:${CLUSTER_PORT}:6443\/tcp/g" \
    runtime/quadlet/kinc-control-plane.container > ~/.config/containers/systemd/kinc-${CLUSTER_NAME}-control-plane.container

echo "✅ Quadlet files installed"

# Step 3: Prepare cluster configuration volume
echo
echo "🔧 Step 3: Preparing cluster configuration volume"
# Create the config volume and copy kubeadm.conf into it
systemctl --user daemon-reload
systemctl --user start kinc-${CLUSTER_NAME}-config-volume.service
# Wait for volume to be created
sleep 2

# Generate cluster-specific kubeadm.conf
VOLUME_PATH=$(podman volume inspect kinc-${CLUSTER_NAME}-config --format "{{.Mountpoint}}")
sed -e "s/clusterName: kinc/clusterName: kinc-${CLUSTER_NAME}/g" \
    -e "s/kinc-control-plane/kinc-${CLUSTER_NAME}-control-plane/g" \
    -e "s|podSubnet: 10\.244\.0\.0/16|podSubnet: ${CLUSTER_POD_SUBNET}|g" \
    -e "s|serviceSubnet: 10\.96\.0\.0/16|serviceSubnet: ${CLUSTER_SERVICE_SUBNET}|g" \
    runtime/config/kubeadm.conf > /tmp/kubeadm-${CLUSTER_NAME}.conf

sudo cp /tmp/kubeadm-${CLUSTER_NAME}.conf "$VOLUME_PATH/kubeadm.conf"
sudo chown $(id -u):$(id -g) "$VOLUME_PATH/kubeadm.conf"
rm -f /tmp/kubeadm-${CLUSTER_NAME}.conf
echo "✅ Cluster configuration volume prepared"

# Step 4: Ensure image is available
echo
echo "🔧 Step 4: Ensuring local image is available"
echo "🏗️ Using local build image: $IMAGE_NAME"
# Check if local image exists
if ! podman images --format "{{.Repository}}:{{.Tag}}" | grep -q "^${IMAGE_NAME}$"; then
    echo "❌ Local image not found: $IMAGE_NAME"
    echo "   Please run: CLUSTER_NAME=${CLUSTER_NAME} ./tools/build.sh"
    exit 1
fi
echo "✅ Local image found"

# Step 5: Update container file with image name
echo
echo "🔧 Step 5: Updating image in container file"
sed -i "s|Image=.*|Image=$IMAGE_NAME|g" ~/.config/containers/systemd/kinc-${CLUSTER_NAME}-control-plane.container
echo "✅ Image updated"

# Step 6: Start services
echo
echo "🚀 Step 6: Starting user services"
systemctl --user daemon-reload

echo "Starting volume service..."
systemctl --user start kinc-${CLUSTER_NAME}-var-data-volume.service

echo "Starting control plane service..."
if ! systemctl --user start kinc-${CLUSTER_NAME}-control-plane.service; then
    echo "❌ Failed to start kinc-${CLUSTER_NAME}-control-plane.service"
    echo
    echo "=== systemd Service Status ==="
    systemctl --user status kinc-${CLUSTER_NAME}-control-plane.service || true
    echo
    echo "=== systemd Service Logs ==="
    journalctl --user -xeu kinc-${CLUSTER_NAME}-control-plane.service --no-pager -n 50 || true
    echo
    echo "=== Container Logs (if any) ==="
    podman logs kinc-${CLUSTER_NAME}-control-plane || true
    echo
    echo "=== Failed systemd Units ==="
    systemctl --user --failed || true
    exit 1
fi

echo "✅ Volume and container services started"

# Step 5: Wait for cluster initialization
echo
echo "✅ Services started successfully!"
echo
echo "🔍 To monitor cluster initialization:"
echo "  ./tools/monitor.sh"
echo
echo "🧪 To run full deployment with monitoring:"
echo "  ./tools/full-deploy.sh"
echo
echo "🛑 To stop and cleanup:"
echo "  systemctl --user stop kinc-${CLUSTER_NAME}-control-plane.service kinc-${CLUSTER_NAME}-var-data-volume.service"
echo "  podman rm -f kinc-${CLUSTER_NAME}-control-plane"
echo "  podman volume rm kinc-${CLUSTER_NAME}-var-data"
echo "  rm -f ~/.config/containers/systemd/kinc-${CLUSTER_NAME}-*.*"
echo "  systemctl --user daemon-reload"
