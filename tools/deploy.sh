#!/bin/bash
set -euo pipefail

echo "🚀 kinc Rootless Quadlet Deployment"
echo "==================================="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

# Configuration: Cluster name and port management
CLUSTER_NAME="${CLUSTER_NAME:-default}"
FORCE_PORT="${FORCE_PORT:-}"  # Allow manual port override

# Image configuration - Single image for all clusters
# All clusters use the same image with different mounted configs
# Allow KINC_IMAGE env var to override default
IMAGE_NAME="${KINC_IMAGE:-localhost/kinc/node:v1.33.5}"

echo "📁 Working directory: $SCRIPT_DIR"
echo "🏷️  Cluster name: $CLUSTER_NAME"
echo "🏷️  Using image: $IMAGE_NAME"
echo ""

# ===========================================================================
# Step 0: System Prerequisites Check
# ===========================================================================
echo "🔍 Step 0: System Prerequisites Check"
echo "───────────────────────────────────"

# Check 1: IP Forwarding (REQUIRED)
ip_forward=$(cat /proc/sys/net/ipv4/ip_forward)
if [ "$ip_forward" != "1" ]; then
  echo "❌ IP forwarding DISABLED"
  echo "   Required for Kubernetes pod networking!"
  echo "   Enable with: sudo sysctl -w net.ipv4.ip_forward=1"
  exit 1
fi
echo "✅ IP forwarding enabled"

# Check 2: Inotify limits (warn only)
max_user_watches=$(cat /proc/sys/fs/inotify/max_user_watches)
max_user_instances=$(cat /proc/sys/fs/inotify/max_user_instances)
if [ "$max_user_watches" -lt 524288 ] || [ "$max_user_instances" -lt 512 ]; then
  echo "⚠️  Inotify limits below recommended (may affect multi-cluster stability)"
  echo "   Current: watches=$max_user_watches, instances=$max_user_instances"
  echo "   Recommended: watches=524288, instances=512"
else
  echo "✅ Inotify limits sufficient"
fi

# Check 3: Failed services (warn only)
failed=$(systemctl --user list-units --state=failed --no-pager --no-legend 2>/dev/null | wc -l)
if [ $failed -gt 0 ]; then
  echo "⚠️  Found $failed failed user service(s) - may indicate previous cluster issues"
else
  echo "✅ No failed services"
fi

# Check 4: Podman
echo "✅ Podman $(podman --version | awk '{print $NF}') available"
echo ""

# Port allocation function - sequential allocation (6443, 6444, 6445...)
# This MUST be sequential because subnet IDs are derived from port's last 2 digits
# Port 6443 → subnet 43, Port 6444 → subnet 44, etc.
get_cluster_port() {
    local cluster_name=$1
    local base_port=6443
    
    if [[ "$cluster_name" == "default" ]]; then
        echo $base_port
        return
    fi
    
    # Get all currently used ports from running/stopped containers
    # Note: Podman's name filter doesn't support wildcards, so use "kinc" and filter with grep
    local used_ports=$(podman ps -a --filter "name=kinc" --format "{{.Names}}\t{{.Ports}}" 2>/dev/null | \
                      grep 'control-plane' | \
                      grep -oE '127\.0\.0\.1:[0-9]+->6443' | \
                      cut -d: -f2 | \
                      cut -d- -f1 | \
                      sort -n | \
                      uniq)
    
    # Find first available port starting from base_port
    local candidate_port=$base_port
    while echo "$used_ports" | grep -q "^${candidate_port}$"; do
        candidate_port=$((candidate_port + 1))
    done
    
    echo $candidate_port
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
if [[ "${USE_BAKED_IN_CONFIG:-}" == "true" ]]; then
    echo "🔧 Step 3: Using baked-in configuration (skipping volume)"
    echo "📋 Baked-in config mode: Cluster will use baked-in config from image"
    # Remove config volume dependency from Quadlet file
    sed -i '/kinc-config-volume.service/d' ~/.config/containers/systemd/kinc-${CLUSTER_NAME}-control-plane.container
    sed -i '/Volume=kinc-.*-config:/d' ~/.config/containers/systemd/kinc-${CLUSTER_NAME}-control-plane.container
    echo "✅ Baked-in configuration mode enabled"
else
    echo "🔧 Step 3: Preparing cluster configuration volume"
    # Create the config volume and copy kubeadm.conf into it
    systemctl --user daemon-reload
    systemctl --user start kinc-${CLUSTER_NAME}-config-volume.service
    
    # Wait for volume to actually be created (systemd-driven, not arbitrary sleep)
    echo "Waiting for config volume to be created..."
    max_wait=30
    waited=0
    while ! podman volume inspect kinc-${CLUSTER_NAME}-config >/dev/null 2>&1; do
        if [ $waited -ge $max_wait ]; then
            echo "❌ Timeout waiting for config volume creation"
            systemctl --user status kinc-${CLUSTER_NAME}-config-volume.service --no-pager
            exit 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
    echo "✅ Config volume created (${waited}s)"

    # Generate cluster-specific kubeadm.conf
    # Important: bindPort must ALWAYS be 6443 (container-internal port)
    # The host port (CLUSTER_PORT) is mapped via podman port forwarding
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
fi

# Step 4: Ensure image is available
echo
echo "🔧 Step 4: Ensuring local image is available"
echo "🏗️ Using local build image: $IMAGE_NAME"
# Check if local image exists using podman image exists (more reliable than grep)
if ! podman image exists "$IMAGE_NAME"; then
    echo "❌ Local image not found: $IMAGE_NAME"
    echo ""
    echo "Available kinc images:"
    podman images | grep -E "kinc|REPOSITORY" || echo "  No kinc images found"
    echo ""
    echo "Please run: CLUSTER_NAME=${CLUSTER_NAME} ./tools/build.sh"
    exit 1
fi
echo "✅ Local image found"

# Step 5: Update container file with cluster-specific settings
echo
echo "🔧 Step 5: Updating container file with cluster-specific settings"
sed -i "s|Image=.*|Image=$IMAGE_NAME|g" ~/.config/containers/systemd/kinc-${CLUSTER_NAME}-control-plane.container
sed -i "s|PublishPort=.*|PublishPort=127.0.0.1:${CLUSTER_PORT}:6443/tcp|g" ~/.config/containers/systemd/kinc-${CLUSTER_NAME}-control-plane.container
sed -i "s|ContainerName=.*|ContainerName=kinc-${CLUSTER_NAME}-control-plane|g" ~/.config/containers/systemd/kinc-${CLUSTER_NAME}-control-plane.container
sed -i "s|HostName=.*|HostName=kinc-${CLUSTER_NAME}-control-plane|g" ~/.config/containers/systemd/kinc-${CLUSTER_NAME}-control-plane.container
echo "✅ Container file updated"

# Step 6: Start services
echo
echo "🚀 Step 6: Starting user services"
systemctl --user daemon-reload

echo "Starting volume service..."
systemctl --user start kinc-${CLUSTER_NAME}-var-data-volume.service

# Wait for var-data volume to actually be created
echo "Waiting for var-data volume to be created..."
max_wait=30
waited=0
while ! podman volume inspect kinc-${CLUSTER_NAME}-var-data >/dev/null 2>&1; do
    if [ $waited -ge $max_wait ]; then
        echo "❌ Timeout waiting for var-data volume creation"
        systemctl --user status kinc-${CLUSTER_NAME}-var-data-volume.service --no-pager
        exit 1
    fi
    sleep 1
    waited=$((waited + 1))
done
echo "✅ Var-data volume created (${waited}s)"

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

# Step 7: Wait for cluster initialization using systemd
echo
echo "⏳ Step 7: Waiting for cluster initialization (systemd-driven)"

# Wait for container service to be active and stable
echo "Checking systemd service status..."
max_wait=60
waited=0
while [ $waited -lt $max_wait ]; do
    if systemctl --user is-active --quiet kinc-${CLUSTER_NAME}-control-plane.service; then
        echo "✅ systemd service is active"
        break
    fi
    if systemctl --user is-failed --quiet kinc-${CLUSTER_NAME}-control-plane.service; then
        echo "❌ systemd service has failed"
        systemctl --user status kinc-${CLUSTER_NAME}-control-plane.service --no-pager
        exit 1
    fi
    echo "  Service not active yet (${waited}/${max_wait}s)..."
    sleep 2
    waited=$((waited + 2))
done

if [ $waited -ge $max_wait ]; then
    echo "❌ Timeout waiting for systemd service to become active"
    systemctl --user status kinc-${CLUSTER_NAME}-control-plane.service --no-pager
    exit 1
fi

# Wait for kinc-init.service inside container to complete
echo "Waiting for kinc-init.service to complete..."
max_wait=1500  # 25 minutes max for initialization
waited=0
while [ $waited -lt $max_wait ]; do
    # Check if container is still running
    if ! podman ps --filter "name=kinc-${CLUSTER_NAME}-control-plane" --format "{{.Names}}" | grep -q "kinc-${CLUSTER_NAME}-control-plane"; then
        echo "❌ Container is not running"
        systemctl --user status kinc-${CLUSTER_NAME}-control-plane.service --no-pager
        exit 1
    fi
    
    # Check if multi-service initialization has completed
    if podman exec kinc-${CLUSTER_NAME}-control-plane test -f /var/lib/kinc-initialized 2>/dev/null; then
        echo "✅ Cluster initialization completed (${waited}s)"
        
        # Verify multi-service architecture
        echo ""
        echo "🔍 Verifying Multi-Service Architecture"
        echo "────────────────────────────────────────"
        
        services_ok=true
        for service in kinc-preflight.service kubeadm-init.service kinc-postinit.service; do
            if podman exec kinc-${CLUSTER_NAME}-control-plane systemctl is-active --quiet $service; then
                echo "✅ $service: active"
            else
                echo "❌ $service: not active"
                services_ok=false
            fi
        done
        
        if [ "$services_ok" = true ]; then
            echo "✅ Multi-service architecture verified"
        else
            echo "⚠️  Warning: Some services not in expected state"
        fi
        
        break
    fi
    
    # Check if any initialization service has failed
    if podman exec kinc-${CLUSTER_NAME}-control-plane systemctl is-failed --quiet kinc-preflight.service 2>/dev/null || \
       podman exec kinc-${CLUSTER_NAME}-control-plane systemctl is-failed --quiet kubeadm-init.service 2>/dev/null || \
       podman exec kinc-${CLUSTER_NAME}-control-plane systemctl is-failed --quiet kinc-postinit.service 2>/dev/null; then
        echo "❌ One or more initialization services have failed"
        echo ""
        echo "Service status:"
        podman exec kinc-${CLUSTER_NAME}-control-plane systemctl status kinc-preflight.service kubeadm-init.service kinc-postinit.service --no-pager || true
        exit 1
    fi
    
    if [ $((waited % 30)) -eq 0 ] && [ $waited -gt 0 ]; then
        echo "  Still initializing... (${waited}/${max_wait}s)"
    fi
    
    sleep 5
    waited=$((waited + 5))
done

if [ $waited -ge $max_wait ]; then
    echo "❌ Timeout waiting for cluster initialization"
    echo
    echo "Service status inside container:"
    podman exec kinc-${CLUSTER_NAME}-control-plane systemctl status kinc-init.service --no-pager || true
    echo
    echo "Recent logs:"
    podman exec kinc-${CLUSTER_NAME}-control-plane journalctl -u kinc-init.service --no-pager -n 50 || true
    exit 1
fi

echo "✅ Cluster initialization completed successfully!"

echo
echo "✅ Deployment complete!"
echo
echo "🔍 To monitor cluster status:"
echo "  CLUSTER_NAME=${CLUSTER_NAME} ./tools/monitor.sh"
echo
echo "🧪 To run tests:"
echo "  CLUSTER_NAME=${CLUSTER_NAME} ./tools/test.sh"
echo
echo "🛑 To stop and cleanup:"
echo "  CLUSTER_NAME=${CLUSTER_NAME} ./tools/cleanup.sh"
