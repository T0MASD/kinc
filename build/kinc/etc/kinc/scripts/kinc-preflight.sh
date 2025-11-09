#!/bin/bash
set -euo pipefail

# Enhanced logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >&2
}

log "=== kinc Preflight Checks Starting ==="

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
timeout_counter=0
max_timeout=60
while ! systemctl is-active crio.service >/dev/null 2>&1; do
    log "Waiting for CRI-O service... (${timeout_counter}s/${max_timeout}s)"
    sleep 2
    timeout_counter=$((timeout_counter + 2))
    if [[ $timeout_counter -ge $max_timeout ]]; then
        log "❌ CRI-O service failed to start within ${max_timeout} seconds"
        exit 1
    fi
done

# Wait for CRI-O socket
log "Waiting for CRI-O socket..."
timeout_counter=0
while ! test -S /var/run/crio/crio.sock; do
    log "Waiting for CRI-O socket... (${timeout_counter}s/${max_timeout}s)"
    sleep 2
    timeout_counter=$((timeout_counter + 2))
    if [[ $timeout_counter -ge $max_timeout ]]; then
        log "❌ CRI-O socket not available within ${max_timeout} seconds"
        exit 1
    fi
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

log "=== kinc Preflight Checks Complete ==="
log "✅ Ready for kubeadm initialization"

exit 0

