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
    echo "[$(date -u +%FT%T.%6NZ)] $1" | tee -a "$KINC_LOG" >&2
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

# Rendered onto tmpfs deliberately. This carries the node's current IP, so it is
# only ever valid for the boot that produced it: kept across a restart, a node
# that came back on a different address would initialise against the old one.
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

# Tell the kubelet how much of this machine is actually ours.
#
# A node reports capacity by reading /proc, and inside a container /proc is the
# host's: on a 2-CPU 4G VM every node of a two-node cluster reports 2 CPU and
# 4G, and the scheduler adds them up to 4 and 8. Measured on an 8-CPU 31G host,
# both nodes reported cpu=8 mem=31Gi and the cluster total came to cpu=16
# mem=62Gi.
#
# A cgroup limit does not fix that by itself, and alone makes it worse: the
# scheduler keeps placing work against the host's numbers while the cgroup
# refuses to run what arrives. systemReserved is the part the scheduler reads -
# capacity still reports what the machine has, allocatable becomes what this
# node may use, and allocatable is what pods are placed against. So reserve
# everything that is not ours.
#
# The share comes from the environment rather than from the cgroup, because the
# container is in its own cgroup namespace: it sees "max" at its own level
# while the limit sits on the parent, so it cannot read its own ceiling.
# Bytes from a size, accepting both spellings and reading both as binary.
#
# systemd's K/M/G are 1024-based and Kubernetes writes Ki/Mi/Gi for the same
# thing, so the two are the same quantity spelled differently and kinc takes
# either. numfmt does not: --from=iec rejects the "i" outright, and --from=auto
# accepts it but then reads a bare "4G" as 4,000,000,000 - which would leave
# the reserve disagreeing with the cgroup limit by 7% without saying so.
bytes_of() { numfmt --from=iec "${1%i}"; }

if [[ -n "${KINC_NODE_MEMORY:-}" || -n "${KINC_NODE_CPUS:-}" ]]; then
    # What this node needs to be a node, before any pod is scheduled.
    #
    # Measured idle on an otherwise empty cluster: a control plane's cgroup held
    # 2956MiB and a worker's 1231MiB. The control plane carries etcd, the API
    # server, the controller-manager and the scheduler as static pods, and a
    # static pod has no memory request - so the scheduler cannot see any of it.
    # Left uncounted, a node limited to 4G advertised all 4G as allocatable
    # while already using 2.9G of it, and a pod requesting 2Gi was admitted into
    # memory that did not exist.
    #
    # Defaults differ by role for that reason, and both are overridable: these
    # are this cluster's measurements, not a law.
    if [[ -f /etc/kinc/join/join.conf ]]; then
        _RESERVE_MEM="${KINC_NODE_RESERVED_MEMORY:-1Gi}"
        _RESERVE_CPU="${KINC_NODE_RESERVED_CPU:-200m}"
    else
        _RESERVE_MEM="${KINC_NODE_RESERVED_MEMORY:-2Gi}"
        _RESERVE_CPU="${KINC_NODE_RESERVED_CPU:-500m}"
    fi

    if [[ -n "${KINC_NODE_MEMORY:-}" ]]; then
        _total_kb=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
        _limit_kb=$(( $(bytes_of "${KINC_NODE_MEMORY}") / 1024 ))
        _kube_kb=$(( $(bytes_of "${_RESERVE_MEM}") / 1024 ))
        if (( _limit_kb > 0 && _limit_kb < _total_kb )); then
            if (( _kube_kb >= _limit_kb )); then
                log "❌ ${_RESERVE_MEM} is reserved for this node's own components but the node is limited to ${KINC_NODE_MEMORY}"
                log "   Nothing would be left to schedule. Raise KINC_NODE_MEMORY or lower KINC_NODE_RESERVED_MEMORY."
                exit 1
            fi
            # systemReserved is everything that is not this node's, kubeReserved is
            # what this node needs to be a node. Allocatable is what remains, and
            # allocatable is the only one the scheduler places against.
            yq eval -i "(select(.kind == \"KubeletConfiguration\") | .systemReserved.memory) = \"$(( _total_kb - _limit_kb ))Ki\"" \
                /tmp/kubeadm-final.conf
            yq eval -i "(select(.kind == \"KubeletConfiguration\") | .kubeReserved.memory) = \"${_kube_kb}Ki\"" \
                /tmp/kubeadm-final.conf
            log "Node memory: ${KINC_NODE_MEMORY} of $(( _total_kb / 1024 ))Mi, less ${_RESERVE_MEM} for the node itself"
            log "   → allocatable $(( (_limit_kb - _kube_kb) / 1024 ))Mi"
            _SYS_MEM_KI="$(( _total_kb - _limit_kb ))Ki"
            _KUBE_MEM_KI="${_kube_kb}Ki"
        else
            log "⚠️  KINC_NODE_MEMORY=${KINC_NODE_MEMORY} is not below this machine's $(( _total_kb / 1024 ))Mi; nothing reserved"
        fi
    fi
    if [[ -n "${KINC_NODE_CPUS:-}" ]]; then
        _total_cpu=$(nproc)
        _reserved=$(awk -v t="$_total_cpu" -v c="${KINC_NODE_CPUS}" 'BEGIN { r = t - c; print (r > 0 ? r : 0) }')
        if [[ "$_reserved" != "0" ]]; then
            yq eval -i "(select(.kind == \"KubeletConfiguration\") | .systemReserved.cpu) = \"${_reserved}\"" \
                /tmp/kubeadm-final.conf
            yq eval -i "(select(.kind == \"KubeletConfiguration\") | .kubeReserved.cpu) = \"${_RESERVE_CPU}\"" \
                /tmp/kubeadm-final.conf
            log "Node CPUs: ${KINC_NODE_CPUS} of ${_total_cpu}, less ${_RESERVE_CPU} for the node itself"
            _SYS_CPU="${_reserved}"
        else
            log "⚠️  KINC_NODE_CPUS=${KINC_NODE_CPUS} is not below this machine's ${_total_cpu}; nothing reserved"
        fi
    fi

    # A worker's kubelet configuration is not this file.
    #
    # kubeadm join downloads the kubelet-config ConfigMap the control plane
    # uploaded and writes /var/lib/kubelet/config.yaml from it, so everything
    # computed above is overwritten by the control plane's numbers - measured:
    # a worker reserving 1Gi and 200m came up advertising the control plane's
    # 2Gi and 500m, because that is what the cluster told it to use.
    #
    # kubeadm applies a patch directory after that download, which is the one
    # point where a node can say something about itself that the cluster does
    # not already know. join.conf names this directory.
    if [[ -f /etc/kinc/join/join.conf ]]; then
        install -d -m 0755 /etc/kinc/patches-runtime
        {
            echo "apiVersion: kubelet.config.k8s.io/v1beta1"
            echo "kind: KubeletConfiguration"
            [[ -n "${_SYS_MEM_KI:-}${_SYS_CPU:-}" ]] && echo "systemReserved:"
            [[ -n "${_SYS_CPU:-}" ]]    && echo "  cpu: \"${_SYS_CPU}\""
            [[ -n "${_SYS_MEM_KI:-}" ]] && echo "  memory: \"${_SYS_MEM_KI}\""
            [[ -n "${_KUBE_MEM_KI:-}" || -n "${_RESERVE_CPU:-}" ]] && echo "kubeReserved:"
            [[ -n "${_RESERVE_CPU:-}" ]] && echo "  cpu: \"${_RESERVE_CPU}\""
            [[ -n "${_KUBE_MEM_KI:-}" ]] && echo "  memory: \"${_KUBE_MEM_KI}\""
        } > /etc/kinc/patches-runtime/kubeletconfiguration.yaml
        log "Worker reserve written as a join patch, which survives the cluster's own config"
    fi
fi

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
    
    # Faro's events directory, owned by the user Faro actually runs as.
    #
    # The manifest mounts it as a hostPath with DirectoryOrCreate, and the
    # kubelet creates it root-owned - while the image declares USER faro, uid
    # 65532. Faro then dies on startup with "failed to create log directory:
    # mkdir /var/faro/events/logs: permission denied" and captures nothing,
    # while the deploy still reports it enabled.
    #
    # It went unnoticed because it used to work by accident: the crun wrapper
    # deleted process.user from every OCI spec, so Faro ran as root like
    # everything else. Creating the directory here is what the accident was
    # standing in for, and it keeps Faro running as itself.
    #
    # DirectoryOrCreate leaves an existing directory alone, ownership included,
    # so preparing it first is enough. The uid is the image's; if it ever
    # changes, ci-verify-faro.sh fails on an observer that captures nothing
    # rather than letting it pass silently again.
    #
    # kinc-faro-kubeconfig.service does this too, deliberately. Here it lands
    # before the manifest is copied below, so on a first boot the kubelet cannot
    # start Faro until the directory is already right. There it runs on every
    # boot, which is what a cluster first initialised before this code existed
    # needs - the directory is on /var, it is root-owned, and preflight is
    # guarded by a marker on /var so it will never run again. Both are
    # idempotent.
    install -d -o 65532 -g 65532 -m 0755 /var/lib/kinc/faro-events
    log "📁 Faro events directory ready, owned by uid 65532 (the image's faro user)"

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

