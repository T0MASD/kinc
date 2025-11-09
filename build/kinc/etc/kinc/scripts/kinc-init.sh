#!/bin/bash
set -euo pipefail

# Enhanced logging function
# Logs to stderr to avoid interfering with function return values captured via command substitution
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >&2
}

# Start overall timing
INIT_START_TIME=$(date +%s)

log "=== kinc Kind-Free Initialization Starting ==="

# Configuration validation and fallback logic 
validate_configuration() {
    local config_path="$1"
    
    if [[ ! -f "$config_path" ]]; then
        log "❌ Configuration file not found: $config_path"
        return 1
    fi
    
    # Basic YAML validation
    if ! command -v yq >/dev/null 2>&1; then
        log "⚠️  yq not available, skipping advanced config validation"
        return 0
    fi
    
    if ! yq eval '.' "$config_path" >/dev/null 2>&1; then
        log "❌ Invalid YAML in configuration: $config_path"
        return 1
    fi
    
    log "✅ Configuration validated: $config_path"
    return 0
}

# Configuration setup with baked-in config and mounted override support
# Priority: Mounted config > Baked-in config
setup_configuration() {
    local mounted_config="/etc/kinc/config/kubeadm.conf"
    local baked_config="/etc/kinc/kubeadm.conf"
    
    if [[ -f "$mounted_config" ]]; then
        # Mounted config takes priority (allows customization)
        log "📋 Using mounted configuration: $mounted_config"
        if validate_configuration "$mounted_config"; then
            echo "$mounted_config"
            return 0
        else
            log "❌ Mounted configuration validation failed"
            exit 1
        fi
    elif [[ -f "$baked_config" ]]; then
        # Fall back to baked-in config
        log "📋 No mounted config found, using baked-in configuration"
        log "📋 Copying baked-in config: $baked_config → $mounted_config"
        cp "$baked_config" "$mounted_config"
        if validate_configuration "$mounted_config"; then
            log "✅ Baked-in configuration copied and validated"
            echo "$mounted_config"
            return 0
        else
            log "❌ Baked-in configuration validation failed"
            exit 1
        fi
    else
        log "❌ No configuration found (neither mounted nor baked-in)"
        exit 1
    fi
}

# Wait for basic systemd services (not full system-running state to avoid circular dependency)
log "Waiting for basic systemd services..."
sleep 5

# Setup and validate configuration
log "Setting up cluster configuration..."
CONFIG_FILE=$(setup_configuration)
log "✅ Configuration ready: $CONFIG_FILE"

# Wait for CRI-O to be ready
log "Waiting for CRI-O to be ready..."
while ! systemctl is-active crio.service >/dev/null 2>&1; do
    log "Waiting for CRI-O service..."
    sleep 2
done

# Wait for CRI-O socket
log "Waiting for CRI-O socket..."
while ! test -S /var/run/crio/crio.sock; do
    log "Waiting for CRI-O socket..."
    sleep 2
done

# Test CRI-O connectivity
log "Testing CRI-O connectivity..."
if crictl --runtime-endpoint unix:///var/run/crio/crio.sock version >/dev/null 2>&1; then
    log "✅ CRI-O is ready and responsive"
else
    log "❌ CRI-O connectivity test failed"
    exit 1
fi

# Get container IP address (in pasta mode this will be the host IP)
# Multiple clusters will share this IP but use different bindPorts
CONTAINER_IP=$(ip route get 1.1.1.1 | awk '{print $7; exit}')
log "Detected container IP: $CONTAINER_IP"

# Validate IP address format
if [[ ! "$CONTAINER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    log "❌ Invalid container IP detected: $CONTAINER_IP"
    exit 1
fi

# Template the kubeadm config with the actual container IP
log "Templating kubeadm configuration with container IP..."
sed "s/CONTAINER_IP_PLACEHOLDER/$CONTAINER_IP/g" "$CONFIG_FILE" > /tmp/kubeadm-final.conf

# Validate the final configuration
if validate_configuration "/tmp/kubeadm-final.conf"; then
    log "✅ Final kubeadm configuration validated"
else
    log "❌ Final kubeadm configuration validation failed"
    exit 1
fi

# Initialize Kubernetes cluster
log "Initializing Kubernetes cluster with kubeadm..."
kubeadm_start=$(date +%s)
# Skip preflight, upload-config/kubelet, and show-join-command phases
# - preflight: We handle checks ourselves
# - upload-config/kubelet: Applied automatically when node registers
# - show-join-command: Suppress verbose join instructions (single-node cluster)
#
# Filter out join command output (kubeadm still prints it even when phase is skipped)
# Keep all other output showing component startup progress
if kubeadm init --config=/tmp/kubeadm-final.conf --skip-phases=preflight,upload-config/kubelet,show-join-command 2>&1 | \
   grep -Ev "(kubeadm join|discovery-token-ca-cert-hash|--control-plane|Then you can join|following as root:$|any number of worker nodes)" | \
   cat; then
    kubeadm_end=$(date +%s)
    kubeadm_elapsed=$((kubeadm_end - kubeadm_start))
    log "✅ Kubernetes cluster initialized successfully (took ${kubeadm_elapsed}s)"
else
    kubeadm_end=$(date +%s)
    kubeadm_elapsed=$((kubeadm_end - kubeadm_start))
    log "❌ Kubernetes cluster initialization failed after ${kubeadm_elapsed}s"
    exit 1
fi

# Wait for node to register (happens automatically when kubelet starts)
log "Waiting for node to register with API server..."
timeout_counter=0
max_timeout=60
while ! kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes 2>/dev/null | grep -q "Ready\|NotReady"; do
    log "Waiting for node registration... (${timeout_counter}s/${max_timeout}s)"
    sleep 2
    timeout_counter=$((timeout_counter + 2))
    if [[ $timeout_counter -ge $max_timeout ]]; then
        log "❌ Node failed to register within ${max_timeout} seconds"
        exit 1
    fi
done
log "✅ Node registered with API server"

# Now complete the kubelet config upload phase that we skipped earlier
log "Completing kubelet configuration upload..."
if kubeadm init phase upload-config kubelet --config=/tmp/kubeadm-final.conf; then
    log "✅ Kubelet configuration uploaded successfully"
else
    log "⚠️  Kubelet config upload failed, but node is registered - continuing..."
fi

# Kubelet configuration is now correctly generated by kubeadm from kubeadm.conf
log "✅ Kubelet configured for rootless operation via kubeadm config"

# Patch kube-proxy to remove privileged flag for rootless operation
log "Patching kube-proxy DaemonSet to remove privileged flag..."
if kubectl --kubeconfig=/etc/kubernetes/admin.conf patch daemonset kube-proxy -n kube-system --type='json' -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/securityContext/privileged", "value": false}]'; then
    log "✅ kube-proxy patched for rootless operation"
else
    log "❌ Failed to patch kube-proxy for rootless operation"
    exit 1
fi

# Wait for API server to be fully ready before installing any manifests
log "Waiting for API server to be ready..."
timeout_counter=0
max_timeout=60
while ! kubectl --kubeconfig=/etc/kubernetes/admin.conf get --raw=/healthz >/dev/null 2>&1; do
    log "Waiting for API server to respond... (${timeout_counter}s/${max_timeout}s)"
    sleep 2
    timeout_counter=$((timeout_counter + 2))
    if [[ $timeout_counter -ge $max_timeout ]]; then
        log "❌ API server failed to become ready within ${max_timeout} seconds"
        exit 1
    fi
done

# Additional check: ensure API server can handle requests properly
log "Verifying API server functionality..."
if kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes >/dev/null 2>&1; then
    log "✅ API server is ready and responsive"
else
    log "API server not fully ready, waiting additional 5 seconds..."
    sleep 5
    if kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes >/dev/null 2>&1; then
        log "✅ API server is now ready and responsive"
    else
        log "❌ API server functionality verification failed"
        exit 1
    fi
fi

# Install CNI (using kinc's default CNI with proper templating)
log "Installing CNI..."
if [[ -f /kinc/manifests/default-cni.yaml ]]; then
    # Template the CNI manifest with our pod subnet (matching kubeadm config)
    log "Templating CNI manifest with pod subnet..."
    sed 's/{{ \.PodSubnet }}/10.244.0.0\/16/g' /kinc/manifests/default-cni.yaml > /tmp/cni-manifest.yaml
    
    if kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f /tmp/cni-manifest.yaml; then
        log "✅ CNI installed successfully"
    else
        log "❌ Failed to install CNI"
        exit 1
    fi
else
    log "❌ CNI manifest not found at /kinc/manifests/default-cni.yaml"
    exit 1
fi

# Wait for CNI to be ready before proceeding
log "Waiting for CNI pods to be ready..."
wait_start=$(date +%s)
if kubectl --kubeconfig=/etc/kubernetes/admin.conf wait --for=condition=Ready pods -l k8s-app=kincnet -n kube-system --timeout=180s; then
    wait_end=$(date +%s)
    wait_elapsed=$((wait_end - wait_start))
    log "✅ CNI pods are ready (waited ${wait_elapsed}s)"
else
    wait_end=$(date +%s)
    wait_elapsed=$((wait_end - wait_start))
    log "⚠️  CNI pods not ready yet after ${wait_elapsed}s, but continuing..."
fi

# Wait for nodes to be ready first
log "Waiting for node to be ready..."
wait_start=$(date +%s)
if kubectl --kubeconfig=/etc/kubernetes/admin.conf wait --for=condition=Ready nodes --all --timeout=240s; then
    wait_end=$(date +%s)
    wait_elapsed=$((wait_end - wait_start))
    log "✅ All nodes are ready (waited ${wait_elapsed}s)"
else
    wait_end=$(date +%s)
    wait_elapsed=$((wait_end - wait_start))
    log "❌ Nodes failed to become ready after ${wait_elapsed}s"
    exit 1
fi

# Wait for control plane pods to be fully ready and stable
log "Waiting for control plane to be completely stable..."
components=("etcd" "kube-apiserver" "kube-controller-manager" "kube-scheduler")
for component in "${components[@]}"; do
    log "Waiting for $component to be ready..."
    wait_start=$(date +%s)
    if kubectl --kubeconfig=/etc/kubernetes/admin.conf wait --for=condition=Ready pod -l component="$component" -n kube-system --timeout=180s; then
        wait_end=$(date +%s)
        wait_elapsed=$((wait_end - wait_start))
        log "✅ $component is ready (waited ${wait_elapsed}s)"
    else
        wait_end=$(date +%s)
        wait_elapsed=$((wait_end - wait_start))
        log "❌ $component failed to become ready after ${wait_elapsed}s"
        exit 1
    fi
done

# Additional stability check - ensure all control plane components are stable
log "Verifying control plane stability..."
sleep 5

# Remove control plane taint so storage provisioner can be scheduled
log "Removing control plane taint to allow workload scheduling..."
if kubectl --kubeconfig=/etc/kubernetes/admin.conf taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule- 2>/dev/null; then
    log "✅ Control plane taint removed"
else
    log "ℹ️  Control plane taint already removed or not present"
fi

# Now install storage class with fully stable control plane
log "Installing storage class..."
if [[ -f /kinc/manifests/default-storage.yaml ]]; then
    if kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f /kinc/manifests/default-storage.yaml; then
        log "✅ Storage class installed successfully"
    else
        log "❌ Failed to install storage class"
        exit 1
    fi
else
    log "❌ Storage manifest not found at /kinc/manifests/default-storage.yaml"
    exit 1
fi

# Wait for storage provisioner to be ready
log "Waiting for storage provisioner to be ready..."
wait_start=$(date +%s)
if kubectl --kubeconfig=/etc/kubernetes/admin.conf wait --for=condition=Available deployment/local-path-provisioner -n local-path-storage --timeout=180s; then
    wait_end=$(date +%s)
    wait_elapsed=$((wait_end - wait_start))
    log "✅ Storage provisioner is ready (waited ${wait_elapsed}s)"
else
    wait_end=$(date +%s)
    wait_elapsed=$((wait_end - wait_start))
    log "⚠️  Storage provisioner not ready after ${wait_elapsed}s, but continuing..."
fi

log "=== kinc Kind-Free Initialization Complete ==="

# Calculate and log total initialization time
INIT_END_TIME=$(date +%s)
TOTAL_INIT_TIME=$((INIT_END_TIME - INIT_START_TIME))

log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "⏱️  INITIALIZATION TIMING SUMMARY"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "   Total initialization time: ${TOTAL_INIT_TIME}s"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "Cluster is ready!"

# Signal that initialization is complete
touch /var/lib/kinc-initialized
log "✅ Initialization marker created at /var/lib/kinc-initialized"

log "=== Continuing with normal systemd operation ==="
