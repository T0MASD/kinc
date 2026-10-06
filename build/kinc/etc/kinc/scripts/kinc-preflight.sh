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
# What a joining node dials. Distinct from advertiseAddress above: that is the
# address the cluster hands to its own clients, this is the one a node outside
# it has to reach. Derived from $(hostname) for a single-machine cluster, which
# resolves only on that machine.
ADV="${CONTROL_PLANE_NAME}"
if [[ -s /etc/kinc/advertise-addr ]]; then
    ADV="$(tr -d '[:space:]' < /etc/kinc/advertise-addr)"
    log "Control-plane endpoint overridden: ${ADV}:6443"
fi
log "Control-plane endpoint: ${CONTROL_PLANE_NAME}:6443"

# Rendered onto tmpfs deliberately. This carries the node's current IP, so it is
# only ever valid for the boot that produced it: kept across a restart, a node
# that came back on a different address would initialise against the old one.
# --- Multi-host transport -------------------------------------------------
# A kinc cluster can span machines. The transport is a WireGuard link this
# container owns, because the two obvious alternatives are both closed:
# rootless podman puts each machine's network in its own user namespace, so one
# machine's node address is unreachable from any other; and the kubelet refuses
# to advertise an address that is not on one of its own interfaces, which rules
# out publishing host ports. A wg0 the container owns satisfies both, and the
# tunnel is established outbound.
#
# This runs before the kubeadm config is templated, and that ordering is the
# point. advertiseAddress must name a local address when kubeadm validates it,
# and it is what the API server writes into endpoints/kubernetes - the address
# every in-cluster client is handed. Set it afterwards and the cluster forms
# with its own Service pointing somewhere no other machine can reach, which
# surfaces as CNI pods crashlooping on an unreachable API rather than as an
# addressing mistake.
#
# A single-machine cluster mounts nothing here and keeps its podman address.
NODE_IP="$CONTAINER_IP"
if [[ -s /etc/kinc/wg/address ]]; then
    # The interface itself belongs to kinc-tunnel.service, which runs on every
    # start. This unit is skipped once the node has initialised, so anything it
    # created would be missing after a restart - which is how a tunnelled node
    # came back with no wg0, no identity, and no way to register.
    NODE_IP="$(tr -d '[:space:]' < /etc/kinc/wg/address)"
    log "Multi-host transport: node address is ${NODE_IP}"
fi

# A named endpoint needs a certificate of its own, or it fails TLS and nothing
# else: discovery succeeds and then every client rejects the certificate, so
# the API reads as unreachable rather than as a bad certificate.
#
# Added here rather than carried as a placeholder in the template, so a cluster
# that does not name its endpoint renders exactly what it always did. The
# append runs before the substitution below, while the line still matches.
ADV_SAN=()
if [[ "$ADV" != "$CONTROL_PLANE_NAME" ]]; then
    ADV_SAN=(-e "/CONTROL_PLANE_NAME_PLACEHOLDER/a\\  - ${ADV}")
fi

# The endpoint is one name among several the API server may be reached by. A
# cluster fronted per-machine is the case that needs this: each kubelet dials a
# proxy on its own hypervisor, so every one of those addresses is a name the
# certificate has to carry, and the endpoint knob can only express one.
#
# kubeadm uploads certSANs into kube-system/kubeadm-config, so a control plane
# joining later mints its serving certificate from this same list without being
# told again. Omitting one surfaces only when a client happens to use it.
EXTRA_SANS=()
if [[ -s /etc/kinc/extra-sans ]]; then
    while read -r san; do
        san="${san%%#*}"
        san="$(tr -d '[:space:]' <<<"$san")"
        [[ -n "$san" ]] || continue
        EXTRA_SANS+=(-e "/CONTROL_PLANE_NAME_PLACEHOLDER/a\\  - ${san}")
        log "Additional API server name: ${san}"
    done < /etc/kinc/extra-sans
fi

sed "${ADV_SAN[@]}" "${EXTRA_SANS[@]}" \
    -e "s/CONTAINER_IP_PLACEHOLDER/$NODE_IP/g" \
    -e "s/CONTROL_PLANE_NAME_PLACEHOLDER/${CONTROL_PLANE_NAME}/g" \
    -e "s/CONTROL_PLANE_ENDPOINT_PLACEHOLDER/${ADV}:6443/g" \
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

# The node's own reservations are not computed here any more.
#
# They were, and they were written into /tmp/kubeadm-final.conf and a join patch
# directory - both of which only a first boot reads, while this unit is gated on
# ConditionPathExists=!/var/lib/kubeadm-initialized and /var is a volume. So a
# cluster that resumed kept whatever it was born with, and a limit added or
# changed later took effect on the cgroup and never on what the node advertised.
#
# kinc-node-resources.service renders them into the kubelet's config directory
# on every boot instead. See /etc/kinc/scripts/kinc-node-resources.sh.

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
#
# A JOINING control plane mounts the same directory, and that is what lets it
# join without a certificate key: kubeadm's --upload-certs path exists to move
# exactly this material, so a node that already has it skips the download and
# never depends on a Secret that expires two hours after the cluster started.
# A control-plane join without that material is refused rather than attempted.
# kubeadm would mint a CA of its own and carry on: the node comes up, serves an
# API, and is rejected by every other member - the failure arrives minutes later
# as "certificate signed by unknown authority" against the cluster it was
# joining, naming neither the missing mount nor the CA it invented.
#
# The join config is what says this is a control plane; a worker holds none of
# this and is unaffected.
if [[ -f /etc/kinc/join/join.conf ]] && grep -q '^controlPlane:' /etc/kinc/join/join.conf; then
    if [[ ! -f /etc/kinc/ca/ca.key || ! -f /etc/kinc/ca/sa.key ]]; then
        log "❌ control-plane join with no shared material at /etc/kinc/ca"
        log "   it needs the cluster's CAs and service account keypair, as"
        log "   minted by deploy.sh in ~/.local/share/kinc/<cluster>/ca"
        log "   without them kubeadm mints its own and the cluster splits"
        exit 1
    fi
fi

if [[ -f /etc/kinc/ca/ca.crt && -f /etc/kinc/ca/ca.key ]]; then
    log "Adopting the pre-minted cluster material"
    install -d -m 0755 /etc/kubernetes/pki /etc/kubernetes/pki/etcd
    # Public half 0644, private half 0600, and each only if it was minted: a
    # cluster from an older state dir has the CA and nothing else, and must
    # still come up rather than fail on a file that was never there.
    for f in ca front-proxy-ca etcd/ca; do
        [[ -f "/etc/kinc/ca/${f}.crt" ]] && install -m 0644 "/etc/kinc/ca/${f}.crt" "/etc/kubernetes/pki/${f}.crt"
        [[ -f "/etc/kinc/ca/${f}.key" ]] && install -m 0600 "/etc/kinc/ca/${f}.key" "/etc/kubernetes/pki/${f}.key"
    done
    [[ -f /etc/kinc/ca/sa.pub ]] && install -m 0644 /etc/kinc/ca/sa.pub /etc/kubernetes/pki/sa.pub
    [[ -f /etc/kinc/ca/sa.key ]] && install -m 0600 /etc/kinc/ca/sa.key /etc/kubernetes/pki/sa.key
    log "✅ Adopted: $(cd /etc/kubernetes/pki && ls ca.crt front-proxy-ca.crt etcd/ca.crt sa.pub 2>/dev/null | tr '\n' ' ')"
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

