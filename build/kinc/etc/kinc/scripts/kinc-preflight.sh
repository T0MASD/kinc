#!/bin/bash
set -euo pipefail

# Enhanced logging function
# Also append to a plain file under /var/log, which deployments publish to the
# hypervisor. journald cannot be used for this: its store needs fallocate and
# mmap semantics that a virtiofs mount does not provide, so it silently stays
# volatile and the account of why a cluster came up is lost with the container.
KINC_LOG="${KINC_LOG:-/var/log/kinc/$(basename "$0" .sh).log}"
mkdir -p "$(dirname "$KINC_LOG")" 2>/dev/null || true
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$KINC_LOG" >&2
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
# The control-plane endpoint is this container's own name, which the quadlet
# sets as HostName and which other nodes resolve over the cluster's podman
# network. Resolving it here rather than in deploy.sh means the baked-in config
# and the mounted one are templated the same way.
#
# A worker renders its own name here and never uses the result: its
# kubeadm-init is replaced by a join, which reads join.conf instead.
CONTROL_PLANE_NAME="$(hostname)"
log "Control-plane endpoint: ${CONTROL_PLANE_NAME}:6443"

sed -e "s/CONTAINER_IP_PLACEHOLDER/$CONTAINER_IP/g" \
    -e "s/CONTROL_PLANE_NAME_PLACEHOLDER/${CONTROL_PLANE_NAME}/g" \
    -e "s/CONTROL_PLANE_ENDPOINT_PLACEHOLDER/${CONTROL_PLANE_NAME}:6443/g" \
    "$CONFIG_FILE" > /tmp/kubeadm-final.conf

# Tell the kubelet the OOM score it can actually hold.
#
# It asks for -999 by default, to keep itself and the runtime off the OOM
# killer's list. Lowering oom_score_adj below the inherited floor needs
# CAP_SYS_RESOURCE in the *initial* user namespace - fs/proc/base.c calls
# capable(), not ns_capable() - so no capability a rootless container can be
# given satisfies it. Verified: the write is refused even under --privileged,
# which holds every capability there is.
#
# So the request fails, the kubelet stays where it was, and it logs an error
# and retries every five minutes for the life of the node. Asking for the value
# it already has ends that: the write is no longer a decrease, so it succeeds,
# and nothing about the node's actual standing with the OOM killer changes -
# it was never going to get -999.
#
# Read rather than hardcoded, because the floor belongs to the session that
# started podman: 200 here, 0 elsewhere, and a value below it fails the same
# way. PID 1 is the container's systemd, which is what the kubelet inherits.
OOM_SCORE_ADJ="$(cat /proc/1/oom_score_adj)"
log "Kubelet oomScoreAdj: ${OOM_SCORE_ADJ} (inherited; -999 is unreachable rootless)"
yq eval -i "(select(.kind == \"KubeletConfiguration\") | .oomScoreAdj) = ${OOM_SCORE_ADJ}" \
    /tmp/kubeadm-final.conf

# Adopt the cluster CA if one was minted for this cluster.
#
# kubeadm creates the CA during init otherwise, which means the hash a joining
# node must pin cannot be known until after the control plane is up - so
# discovery becomes something a node learns rather than something its config
# states. Minting the CA first lets every join config carry the hash from the
# start, so a worker needs nothing from this filesystem and can start in any
# order. kubeadm uses an existing ca.crt/ca.key as-is and mints the rest.
#
# A worker has no CA mount and skips this: it authenticates the control plane
# by the hash its join config already carries.
if [[ -f /etc/kinc/ca/ca.crt && -f /etc/kinc/ca/ca.key ]]; then
    log "Adopting the pre-minted cluster CA"
    install -d -m 0755 /etc/kubernetes/pki
    install -m 0644 /etc/kinc/ca/ca.crt /etc/kubernetes/pki/ca.crt
    install -m 0600 /etc/kinc/ca/ca.key /etc/kubernetes/pki/ca.key
    log "✅ Cluster CA adopted"
fi

# API-server audit logging, when KINC_AUDIT_RESOURCES names something.
#
# A GET or LIST changes nothing, so it raises no watch event and is invisible to
# every informer - the audit log is the only place a read is recorded. That is
# what this is for, and why the policy is narrow rather than catch-all: an
# audit-everything policy is a volume problem, and naming the resources is the
# point. Each entry is "<group>/<resource>"; the core group is empty, so "/pods".
#
# DELETE is recorded alongside the reads. It does raise a watch event, so Faro
# sees the object go - but a watch says only that it is gone, never who removed
# it, and the object is past tense by the time anything can be asked about it.
# The deleter's identity exists in one place only, and this is it. It is also
# what makes a denial legible after the fact: the API returns Forbidden rather
# than NotFound for an object the caller may no longer name, so a delete and the
# refusals that follow it read as one sequence instead of two unrelated ones.
#
# Unset, nothing here runs and the API server starts with no audit flags at all.
#
# A worker never serves the API, so it has no policy to write.
if [[ -n "${KINC_AUDIT_RESOURCES:-}" ]]; then
    log "🔎 KINC_AUDIT_RESOURCES set, enabling API-server audit: ${KINC_AUDIT_RESOURCES}"

    install -d -m 0755 /etc/kubernetes/audit /var/log/kubernetes/audit

    # Metadata, not Request or RequestResponse: user, impersonatedUser, verb,
    # objectRef, sourceIPs and timestamps, without any body.
    # RequestReceived is dropped because ResponseComplete is the stage worth
    # keeping, and omitting it halves the event count.
    {
        echo "apiVersion: audit.k8s.io/v1"
        echo "kind: Policy"
        echo "omitStages:"
        echo "  - RequestReceived"
        echo "rules:"
        IFS=',' read -ra _entries <<< "$KINC_AUDIT_RESOURCES"
        for entry in "${_entries[@]}"; do
            entry="$(echo "$entry" | tr -d '[:space:]')"
            [[ -z "$entry" ]] && continue
            group="${entry%%/*}"
            resource="${entry#*/}"
            echo "  - level: Metadata"
            echo "    verbs: [\"get\", \"list\", \"watch\", \"delete\"]"
            echo "    resources:"
            echo "      - group: \"${group}\""
            echo "        resources: [\"${resource}\"]"
        done
        echo "  # Everything else on this cluster: not logged."
        echo "  - level: None"
    } > /etc/kubernetes/audit/policy.yaml

    if ! yq eval '.' /etc/kubernetes/audit/policy.yaml >/dev/null 2>&1; then
        log "❌ Generated audit policy is not valid YAML"
        cat /etc/kubernetes/audit/policy.yaml
        exit 1
    fi
    log "   policy: $(grep -c 'level: Metadata' /etc/kubernetes/audit/policy.yaml) audited resource(s)"

    # Injected with yq, not sed: the config is four YAML documents and the
    # flags belong only to ClusterConfiguration. v1beta4 takes extraArgs as a
    # list of name/value pairs, not a map.
    #
    # A static pod sees only what is mounted into it, and hostPath here is this
    # container's filesystem. /var is the cluster's own volume, so the log
    # outlives a container restart and is readable from the host.
    yq eval -i '
      (select(.kind == "ClusterConfiguration") | .apiServer.extraArgs) +=
        [{"name": "audit-policy-file", "value": "/etc/kubernetes/audit/policy.yaml"},
         {"name": "audit-log-path", "value": "/var/log/kubernetes/audit/audit.log"},
         {"name": "audit-log-maxage", "value": "30"},
         {"name": "audit-log-maxbackup", "value": "10"},
         {"name": "audit-log-maxsize", "value": "100"}] |
      (select(.kind == "ClusterConfiguration") | .apiServer.extraVolumes) =
        [{"name": "audit-policy", "hostPath": "/etc/kubernetes/audit",
          "mountPath": "/etc/kubernetes/audit", "readOnly": true, "pathType": "DirectoryOrCreate"},
         {"name": "audit-log", "hostPath": "/var/log/kubernetes/audit",
          "mountPath": "/var/log/kubernetes/audit", "pathType": "DirectoryOrCreate"}]
    ' /tmp/kubeadm-final.conf

    log "✅ Audit logging configured"
else
    log "🔕 KINC_AUDIT_RESOURCES not set, API server starts with no audit flags"
fi

# Pull the control-plane images before kubeadm needs them.
#
# kubeadm bootstraps the admin user under a deadline that assumes the API
# server is coming up, not still downloading. With a warm image store that is
# always true and this is a no-op; with a cold one the static pods are still
# pulling when the deadline expires, and it fails as "could not bootstrap the
# admin user" rather than as a slow pull.
#
# Only the control-plane set: the CNI and storage images are pulled later, by
# postinit, whose waits are sized for it. `kubeadm config images list` does not
# name them.
#
# A worker runs a join and needs none of this, so it is skipped there.
if [[ ! -f /etc/kinc/join/join.conf ]]; then
    pull_start=$(date +%s)

    # Ask the local store first. 'kubeadm config images pull' contacts the
    # registry for every image even when all of them are present, which costs
    # about as long as the bootstrap it is protecting. crictl answers from the
    # store, so a warm node skips the network entirely.
    missing=""
    for img in $(kubeadm config images list --config=/tmp/kubeadm-final.conf 2>/dev/null); do
        if [[ -z "$(crictl --runtime-endpoint unix:///var/run/crio/crio.sock images -q "$img" 2>/dev/null)" ]]; then
            missing="$missing $img"
        fi
    done

    if [[ -z "$missing" ]]; then
        log "✅ Control-plane images already present ($(($(date +%s) - pull_start))s)"
    else
        log "Pre-pulling control-plane images:$missing"
        if kubeadm config images pull --config=/tmp/kubeadm-final.conf 2>&1 | while IFS= read -r line; do log "   $line"; done; then
            log "✅ Control-plane images present ($(($(date +%s) - pull_start))s)"
        else
            # Not fatal: kubeadm will pull them itself, just against its own clock.
            log "⚠️  Pre-pull did not complete; kubeadm will pull during init"
        fi
    fi
fi

# Validate the final configuration
if validate_configuration "/tmp/kubeadm-final.conf"; then
    log "✅ Final kubeadm configuration validated"
else
    log "❌ Final kubeadm configuration validation failed"
    exit 1
fi

# Conditional Faro deployment based on environment variable
if [[ "${KINC_ENABLE_FARO:-false}" == "true" ]]; then
    log "🔍 KINC_ENABLE_FARO=true detected, deploying Faro bootstrap observer..."
    
    if [[ -f "/etc/kinc/faro/faro-bootstrap.yaml" ]]; then
        # Extract Faro image name from manifest using yq (proper YAML parsing)
        FARO_IMAGE=$(yq eval '.spec.containers[0].image' /etc/kinc/faro/faro-bootstrap.yaml)
        
        if [[ -n "$FARO_IMAGE" && "$FARO_IMAGE" != "null" ]]; then
            log "📥 Pre-pulling Faro operator image: $FARO_IMAGE"
            log "   (This eliminates ~20s delay when static pod starts)"
            
            if crictl --runtime-endpoint unix:///var/run/crio/crio.sock pull "$FARO_IMAGE" 2>&1 | while IFS= read -r line; do log "   $line"; done; then
                log "✅ Faro image pulled successfully"
            else
                log "⚠️  Failed to pre-pull Faro image, will be pulled on-demand"
            fi
        else
            log "⚠️  Could not extract Faro image name from manifest"
        fi
        
        # Deploy manifest
        cp /etc/kinc/faro/faro-bootstrap.yaml /etc/kubernetes/manifests/faro-bootstrap.yaml
        log "✅ Faro static pod manifest deployed to /etc/kubernetes/manifests/"
        log "📊 Faro will start capturing events as soon as API server is ready"
    else
        log "⚠️  Faro manifest not found at /etc/kinc/faro/faro-bootstrap.yaml"
        log "⚠️  Continuing without Faro event capture"
    fi
else
    log "🔕 KINC_ENABLE_FARO not set, skipping Faro deployment"
    log "💡 To enable event capture, set KINC_ENABLE_FARO=true"
    
    # Clean up any existing Faro manifest (in case it was left from previous run)
    if [[ -f "/etc/kubernetes/manifests/faro-bootstrap.yaml" ]]; then
        rm -f /etc/kubernetes/manifests/faro-bootstrap.yaml
        log "🧹 Removed existing Faro manifest"
    fi
fi

log "=== kinc Preflight Checks Complete ==="
log "✅ Ready for kubeadm initialization"

exit 0

