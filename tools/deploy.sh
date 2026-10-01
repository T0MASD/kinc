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
IMAGE_NAME="${KINC_IMAGE:-localhost/kinc/node:v1.37.0}"

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

# Check 2: Inotify limits
max_user_watches=$(cat /proc/sys/fs/inotify/max_user_watches)
max_user_instances=$(cat /proc/sys/fs/inotify/max_user_instances)
# Count existing kinc clusters
existing_clusters=$(podman ps --filter "name=kinc-" --format "{{.Names}}" 2>/dev/null | wc -l)

if [ "$max_user_watches" -lt 524288 ] || [ "$max_user_instances" -lt 2048 ]; then
  echo "⚠️  Inotify limits below recommended"
  echo "   Current: watches=$max_user_watches, instances=$max_user_instances"
  echo "   Recommended: watches=524288, instances=2048"
  echo "   To fix: sudo sysctl -w fs.inotify.max_user_watches=524288"
  echo "           sudo sysctl -w fs.inotify.max_user_instances=2048"
  
  # If multiple clusters already exist, require proper limits
  if [ "$existing_clusters" -ge 1 ]; then
    echo "❌ CRITICAL: Multi-cluster deployment requires proper inotify limits"
    echo "   Found $existing_clusters existing cluster(s)"
    echo "   Set KINC_SKIP_SYSCTL_CHECKS=true to bypass (not recommended)"
    [ "${KINC_SKIP_SYSCTL_CHECKS:-false}" != "true" ] && exit 1
  else
    echo "   Single cluster may work, but failures likely with multiple clusters"
  fi
else
  echo "✅ Inotify limits sufficient"
fi

# Check 3: Kernel keyring limits
maxkeys=$(cat /proc/sys/kernel/keys/maxkeys 2>/dev/null || echo "1000")
maxbytes=$(cat /proc/sys/kernel/keys/maxbytes 2>/dev/null || echo "25000")
if [ "$maxkeys" -lt 1000 ] || [ "$maxbytes" -lt 25000 ]; then
  echo "⚠️  Kernel keyring limits below recommended"
  echo "   Current: maxkeys=$maxkeys, maxbytes=$maxbytes"
  echo "   Recommended: maxkeys=1000, maxbytes=25000"
  echo "   To fix: sudo sysctl -w kernel.keys.maxkeys=1000"
  echo "           sudo sysctl -w kernel.keys.maxbytes=25000"
  
  # If multiple clusters already exist, require proper limits
  if [ "$existing_clusters" -ge 1 ]; then
    echo "❌ CRITICAL: Multi-cluster deployment requires proper kernel keyring limits"
    echo "   Found $existing_clusters existing cluster(s)"
    echo "   Set KINC_SKIP_SYSCTL_CHECKS=true to bypass (not recommended)"
    [ "${KINC_SKIP_SYSCTL_CHECKS:-false}" != "true" ] && exit 1
  else
    echo "   Single cluster may work, but will limit total cluster count"
  fi
else
  echo "✅ Kernel keyring limits sufficient"
fi

# Check 4: Mandatory access control
# The two systems need different things. SELinux labels the config volume, and
# the container mounts it with :Z, so the labels have to be restored after the
# file is written. AppArmor does no labelling, and instead governs whether
# unprivileged user namespaces are available, which rootless Podman needs to
# create the cluster container at all. Record which is active so the volume
# step and the CI logs name it.
KINC_MAC="none"
if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" != "Disabled" ]; then
  KINC_MAC="selinux"
  echo "✅ SELinux active ($(getenforce 2>/dev/null))"
elif [ "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null)" = "Y" ]; then
  KINC_MAC="apparmor"
  # Ask Podman to make a user namespace rather than reading the sysctl and
  # inferring. Ubuntu sets kernel.apparmor_restrict_unprivileged_userns to 1
  # and ships a profile granting Podman "userns create", so the restriction is
  # on and rootless Podman works anyway. Reading the sysctl alone reports a
  # problem on every Ubuntu host that has none.
  if podman unshare true >/dev/null 2>&1; then
    echo "✅ AppArmor active, user namespaces available to Podman"
  else
    echo "⚠️  AppArmor active, and Podman cannot create a user namespace"
    if [ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)" = "1" ]; then
      echo "   kernel.apparmor_restrict_unprivileged_userns is 1 and no profile grants Podman 'userns create'"
      echo "   To fix: sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0"
    fi
    echo "   Podman reports its own error below if it cannot proceed"
  fi
else
  echo "✅ Kernel MAC: none active"
fi
export KINC_MAC

# Check 5: Kernel modules Antrea's datapath needs
#
# Antrea's datapath is Open vSwitch, and geneve encapsulates traffic between
# nodes. A single-node cluster never tunnels, but the host contract is the same
# either way: a rootless nested container cannot load a kernel module itself,
# because autoloading happens on behalf of the calling process and needs
# CAP_SYS_MODULE against the host kernel, which a user namespace never grants.
# Requiring both here is what keeps a multi-node cluster built on kinc working.
#
# Without them the cluster still reports success: kubeadm completes, the marker
# is written, and the failure surfaces later as CoreDNS stuck in
# ContainerCreating with antrea-agent in Init:Error.
#
# A module compiled into the kernel is available without appearing in
# /sys/module, so modules.builtin is consulted as well. Checking only
# /sys/module reports a builtin geneve as missing.
module_available() {
  [ -d "/sys/module/$1" ] && return 0
  grep -qw "$1" "/lib/modules/$(uname -r)/modules.builtin" 2>/dev/null && return 0
  grep -qw "^$1" /proc/modules 2>/dev/null && return 0
  return 1
}

missing_modules=""
for m in openvswitch geneve; do
  module_available "$m" || missing_modules="$missing_modules $m"
done
if [ -n "$missing_modules" ]; then
  echo "❌ Kernel modules not available:$missing_modules"
  echo "   Antrea's datapath needs them, and a rootless container cannot load them"
  echo "   To fix: sudo modprobe$missing_modules"
  echo "   Persist: printf 'openvswitch\\ngeneve\\n' | sudo tee /etc/modules-load.d/kinc.conf"
  [ "${KINC_SKIP_SYSCTL_CHECKS:-false}" != "true" ] && exit 1
else
  echo "✅ Antrea kernel modules available (openvswitch, geneve)"
fi

# Check 6: Failed services (warn only)
failed=$(systemctl --user list-units --state=failed --no-pager --no-legend 2>/dev/null | wc -l)
if [ $failed -gt 0 ]; then
  echo "⚠️  Found $failed failed user service(s) - may indicate previous cluster issues"
else
  echo "✅ No failed services"
fi

# Check 5: Podman
echo "✅ Podman $(podman --version | awk '{print $NF}') available"
echo ""

# Port allocation function - sequential allocation (6443, 6444, 6445...)
# This MUST be sequential because subnet IDs are derived from port's last 2 digits
# Port 6443 → subnet 43, Port 6444 → subnet 44, etc.
# Uses flock for race-condition-free port allocation
get_cluster_port() {
    local cluster_name=$1
    local base_port=6443
    local lockfile="/tmp/kinc-port-allocation.lock"
    
    if [[ "$cluster_name" == "default" ]]; then
        echo $base_port
        return
    fi
    
    # Acquire exclusive lock to prevent race conditions during rapid deployments
    # Use flock with a file descriptor that works reliably across subshells
    (
        flock -x 9
        
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
    ) 9>"$lockfile"
}

# CIDR allocation functions - mapped from port last 2 digits
#
# A /21 per cluster, not a /24. The controller-manager carves a /24 per node
# out of this, so a /24 held exactly one node and a second one never got a pod
# CIDR - it registered, stayed NotReady, and Antrea had nothing to configure.
# A /21 is eight nodes per cluster and 32 clusters inside 10.244.0.0/16.
get_cluster_pod_subnet() {
    local port=$1

    # Extract last 2 digits from port (6443 -> 43, 6444 -> 44, etc.)
    local subnet_id=${port: -2}
    # Index from the first port so the blocks start at 10.244.0.0 and pack.
    local block=$(( (subnet_id - 43) * 8 ))
    if [ "$block" -lt 0 ] || [ "$block" -gt 248 ]; then
        echo "❌ Port $port maps outside 10.244.0.0/16 (block $block)" >&2
        exit 1
    fi
    echo "10.244.${block}.0/21"
}

get_cluster_service_subnet() {
    local port=$1
    
    # Extract last 2 digits from port (6443 -> 43, 6444 -> 44, etc.)
    local subnet_id=${port: -2}
    echo "10.${subnet_id}.0.0/16"
}

# The subnet the node containers themselves sit on, keyed the same way.
#
# Fixed rather than allocated, because each node is then given a fixed address
# in it, and a node's address is written into its own serving certificate.
# 10.89 is podman's own range for named networks and the third octet is the
# cluster id, so two clusters never share one: port 6443 is 10.89.43.0/24.
#
# Distinct from both of the above - services are 10.<id>.0.0/16 and pods are
# 10.244.<block>.0/21 - so nothing here overlaps anything inside the cluster.
get_cluster_node_subnet() {
    local port=$1
    local subnet_id=${port: -2}
    echo "10.89.${subnet_id}.0/24"
}

# .1 is the gateway, .2 is the control plane, workers count up from .3.
get_cluster_node_ip() {
    local port=$1 index=$2      # index 0 = control plane, 1 = w1, ...
    local subnet_id=${port: -2}
    echo "10.89.${subnet_id}.$(( index + 2 ))"
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
CLUSTER_NODE_SUBNET=$(get_cluster_node_subnet "$CLUSTER_PORT")
CLUSTER_NODE_GATEWAY="${CLUSTER_NODE_SUBNET%.*/*}.1"
CONTROL_PLANE_IP=$(get_cluster_node_ip "$CLUSTER_PORT" 0)

echo "🌐 API Server will be available at: https://127.0.0.1:${CLUSTER_PORT}"
echo "🔗 Pod subnet: $CLUSTER_POD_SUBNET"
echo "🔗 Service subnet: $CLUSTER_SERVICE_SUBNET"
echo "🔗 Node subnet: $CLUSTER_NODE_SUBNET (control plane ${CONTROL_PLANE_IP})"

# Check for conflicts with existing clusters
if systemctl --user is-active kinc-${CLUSTER_NAME}-control-plane.service >/dev/null 2>&1; then
    echo "⚠️  Cluster '${CLUSTER_NAME}' is already running"
    echo "   Use 'CLUSTER_NAME=${CLUSTER_NAME} ./tools/cleanup.sh' to stop it first"
    echo "   Or choose a different cluster name for concurrent deployment"
    exit 1
fi

# How many workers to join to this cluster. 0 keeps the single-node shape.
KINC_WORKERS="${KINC_WORKERS:-0}"

# What each node may use, and what the cluster may use in total.
#
# Unset means unlimited, which is what kinc has always done and stays the
# default: on a workstation the host is also doing other things, and a limit
# guessed on the user's behalf is worse than none.
#
# Set, they are systemd resource control on the node's own unit. podman nests
# the container's payload cgroup under it, so the limit covers the kubelet,
# CRI-O and every pod scheduled onto that node - not one process inside it.
#
#   KINC_NODE_MEMORY=2G      MemoryMax per node
#   KINC_NODE_CPUS=1         CPUQuota per node, in cores
#   KINC_CLUSTER_MEMORY=4G   MemoryMax across the whole cluster
#   KINC_CLUSTER_CPUS=2      CPUQuota across the whole cluster
#
# A node reports capacity from /proc, which inside a container is the host's,
# so a limit alone would leave the scheduler placing work the cgroup then
# refuses to run. KINC_NODE_MEMORY and KINC_NODE_CPUS are therefore passed into
# the node as well, where kinc-preflight turns them into systemReserved so that
# allocatable matches what the node may actually have.
NODE_LIMITS=""
if [ -n "${KINC_NODE_MEMORY:-}" ]; then
    # MemoryHigh is the limit; MemoryMax is a backstop above it.
    #
    # MemoryHigh throttles and reclaims, MemoryMax kills. Setting only the kill
    # means a node that drifts over its budget loses a process rather than
    # slowing down, and the kernel picks which - inside a node the control
    # plane sits at the inherited oom_score_adj floor, so it survives ordinary
    # pods, but nothing about that is graceful. Throttling first gives the
    # kubelet and the workload a chance to give memory back.
    #
    # The backstop is 10% above, so the kill is a genuine last resort rather
    # than the first thing that happens at the limit.
    NODE_LIMITS="MemoryHigh=${KINC_NODE_MEMORY}"
    _max=$(numfmt --from=iec "${KINC_NODE_MEMORY%i}" 2>/dev/null) \
        && NODE_LIMITS="${NODE_LIMITS}\nMemoryMax=$(( _max * 110 / 100 ))"
fi
if [ -n "${KINC_NODE_CPUS:-}" ]; then
    quota=$(awk -v c="${KINC_NODE_CPUS}" 'BEGIN { printf "%d", c * 100 }')
    NODE_LIMITS="${NODE_LIMITS:+${NODE_LIMITS}\n}CPUQuota=${quota}%"
fi

CLUSTER_LIMITS=""
if [ -n "${KINC_CLUSTER_MEMORY:-}" ]; then
    CLUSTER_LIMITS="MemoryHigh=${KINC_CLUSTER_MEMORY}"
    _max=$(numfmt --from=iec "${KINC_CLUSTER_MEMORY%i}" 2>/dev/null) \
        && CLUSTER_LIMITS="${CLUSTER_LIMITS}\nMemoryMax=$(( _max * 110 / 100 ))"
fi

# A cluster budget below the sum of its nodes' is the point, not a mistake.
#
# This used to be refused as contradictory. It is not: it is overcommit with an
# aggregate ceiling, and it is the combination worth having. Per-node alone
# bounds each node and promises nothing about the total, so two 4G nodes can
# want 8G of a 7G host. Per-cluster alone bounds the total and lets one node
# starve another. Both, with the cluster below the sum, says each node may
# spike to its limit while together they may not exceed the cluster's - which
# is how you would divide a small VM.
#
# It degrades rather than breaks, because the slice carries MemoryHigh: memory
# pressure there reclaims across the cluster before MemoryMax kills anything.
#
# Refusing it also made the cluster limit useless whenever a node limit was
# set, since forcing cluster >= sum means the cluster can never bind first.
if [ -n "${KINC_CLUSTER_CPUS:-}" ]; then
    quota=$(awk -v c="${KINC_CLUSTER_CPUS}" 'BEGIN { printf "%d", c * 100 }')
    CLUSTER_LIMITS="${CLUSTER_LIMITS:+${CLUSTER_LIMITS}\n}CPUQuota=${quota}%"
fi
CLUSTER_SLICE="kinc-${CLUSTER_NAME}.slice"
CONTROL_PLANE_NAME="kinc-${CLUSTER_NAME}-control-plane"
CONTROL_PLANE_ENDPOINT="${CONTROL_PLANE_NAME}:6443"
NETWORK_NAME="kinc-${CLUSTER_NAME}"
NETWORK_UNIT="kinc-${CLUSTER_NAME}.network"
STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/kinc/${CLUSTER_NAME}"

if [ "$KINC_WORKERS" -gt 0 ]; then
    echo "👥 Workers: $KINC_WORKERS (cluster endpoint ${CONTROL_PLANE_ENDPOINT})"
fi

# Clean up any leftover artifacts from previous failed deployments
echo
echo "🧹 Step 1: Cleaning up any leftover artifacts"
rm -f ~/.config/containers/systemd/kinc-${CLUSTER_NAME}-*.*
systemctl --user daemon-reload
systemctl --user reset-failed 2>/dev/null || true
echo "✅ Ready for deployment"

# Step 1b: Mint the cluster CA, before any node starts.
#
# kubeadm would create it during init, which means the hash a joining node must
# pin cannot be known until the control plane is already up - discovery becomes
# something a node learns rather than something its config states. Minting it
# here lets every join config carry the hash from the start.
#
# The CA is the cluster's, not a node's: it is reused across redeploys of the
# same cluster name so a node's join config stays valid, and removed by
# cleanup.sh with the rest of the cluster.
echo
# kinc's own image store: one per node, under this cluster's state directory so
# cleanup.sh takes it with the rest.
#
# Per node, not per cluster. containers/storage is single-writer - two CRI-O
# daemons pointed at one directory each garbage-collect the layers the other
# still references, and the loser ends up running containers with no rootfs.
# Created here so it is owned by this user before the container relabels it: a
# :Z mount on a root-owned directory fails.
node_store() {
    local dir="${STATE_DIR}/stores/$1"
    mkdir -p "$dir"
    printf '%s' "$dir"
}

# Where this cluster's PersistentVolumes live: one podman volume, mounted by
# every node. Named rather than a host path so 'podman volume export' moves a
# cluster's data and cleanup.sh removes it with everything else.
CLUSTER_STORAGE="kinc-${CLUSTER_NAME}-storage"

echo "🔑 Step 1b: Minting the cluster CA"
mkdir -p "${STATE_DIR}/ca"
if [ -f "${STATE_DIR}/ca/ca.crt" ] && [ -f "${STATE_DIR}/ca/ca.key" ]; then
    echo "✅ Reusing the CA already minted for cluster '${CLUSTER_NAME}'"
else
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -subj "/CN=kubernetes" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign,digitalSignature" \
        -keyout "${STATE_DIR}/ca/ca.key" -out "${STATE_DIR}/ca/ca.crt" 2>/dev/null
    chmod 0600 "${STATE_DIR}/ca/ca.key"
    echo "✅ CA minted"
fi

# The hash a joining node pins. kubeadm compares it against the DER of the
# public key, not the certificate, so this is SubjectPublicKeyInfo.
CA_HASH=$(openssl x509 -in "${STATE_DIR}/ca/ca.crt" -noout -pubkey \
    | openssl pkey -pubin -outform DER 2>/dev/null \
    | openssl dgst -sha256 | awk '{print $NF}')
if [ ${#CA_HASH} -ne 64 ]; then
    echo "❌ CA hash is not a sha256 digest: '$CA_HASH'"
    exit 1
fi
echo "🔑 CA hash: sha256:${CA_HASH}"

# Step 2: Install Quadlet files with cluster-specific names
echo
echo "📦 Step 2: Installing Quadlet files"
mkdir -p ~/.config/containers/systemd/

# The cluster's own podman network. A worker resolves the control plane by name
# on it; the default rootless network has no DNS at all.
sed -e "s/NETWORK_NAME_PLACEHOLDER/${NETWORK_NAME}/g" \
    -e "s|NODE_SUBNET_PLACEHOLDER|${CLUSTER_NODE_SUBNET}|g" \
    -e "s|NODE_GATEWAY_PLACEHOLDER|${CLUSTER_NODE_GATEWAY}|g" \
    runtime/quadlet/kinc-cluster.network > ~/.config/containers/systemd/${NETWORK_UNIT}

# Copy and customize volume files
sed "s/VolumeName=kinc-var-data/VolumeName=kinc-${CLUSTER_NAME}-var-data/g" \
    runtime/quadlet/kinc-var-data.volume > ~/.config/containers/systemd/kinc-${CLUSTER_NAME}-var-data.volume

sed "s/VolumeName=kinc-config/VolumeName=kinc-${CLUSTER_NAME}-config/g" \
    runtime/quadlet/kinc-config.volume > ~/.config/containers/systemd/kinc-${CLUSTER_NAME}-config.volume

sed "s/VolumeName=kinc-storage/VolumeName=${CLUSTER_STORAGE}/g" \
    runtime/quadlet/kinc-storage.volume > ~/.config/containers/systemd/${CLUSTER_STORAGE}.volume

# The node's share, passed in as well as enforced.
#
# The cgroup bounds what the node may use; this is how the kubelet learns the
# same number, because a container cannot read a limit set on its parent. Both
# halves are needed: without the cgroup nothing is enforced, and without this
# the scheduler places work against the host's totals that the cgroup refuses.
NODE_ENV=""
[ -n "${KINC_NODE_MEMORY:-}" ] && NODE_ENV="${NODE_ENV}Environment=KINC_NODE_MEMORY=${KINC_NODE_MEMORY}\n"
[ -n "${KINC_NODE_CPUS:-}" ]   && NODE_ENV="${NODE_ENV}Environment=KINC_NODE_CPUS=${KINC_NODE_CPUS}\n"

# The cluster's cgroup. Written whether or not it carries limits, so every
# node of a cluster is grouped under one slice and `systemd-cgls` shows a
# cluster as a cluster.
mkdir -p ~/.config/systemd/user
sed "s|CLUSTER_LIMITS_PLACEHOLDER|${CLUSTER_LIMITS}|" \
    runtime/quadlet/kinc-cluster.slice > ~/.config/systemd/user/${CLUSTER_SLICE}
if [ -n "$CLUSTER_LIMITS" ]; then
    echo "🧮 Cluster limits: $(printf '%b' "$CLUSTER_LIMITS" | tr '\n' ' ')"
fi
if [ -n "$NODE_LIMITS" ]; then
    echo "🧮 Per-node limits: $(printf '%b' "$NODE_LIMITS" | tr '\n' ' ')"
fi

# What kubeadm wrote about this node, so a restart comes back as the same node.
sed "s/VolumeName=kinc-etc-kubernetes/VolumeName=kinc-${CLUSTER_NAME}-etc-kubernetes/g" \
    runtime/quadlet/kinc-etc-kubernetes.volume \
    > ~/.config/containers/systemd/kinc-${CLUSTER_NAME}-etc-kubernetes.volume

# Copy and customize container file
sed -e "s/ContainerName=kinc-control-plane/ContainerName=kinc-${CLUSTER_NAME}-control-plane/g" \
    -e "s/HostName=kinc-control-plane/HostName=kinc-${CLUSTER_NAME}-control-plane/g" \
    -e "s/Volume=kinc-var-data:/Volume=kinc-${CLUSTER_NAME}-var-data:/g" \
    -e "s/Volume=kinc-config:/Volume=kinc-${CLUSTER_NAME}-config:/g" \
    -e "s/kinc-var-data-volume.service/kinc-${CLUSTER_NAME}-var-data-volume.service/g" \
    -e "s/kinc-config-volume.service/kinc-${CLUSTER_NAME}-config-volume.service/g" \
    -e "s/PublishPort=127.0.0.1:6443:6443\/tcp/PublishPort=127.0.0.1:${CLUSTER_PORT}:6443\/tcp/g" \
    -e "s|CA_DIR_PLACEHOLDER|${STATE_DIR}/ca|g" \
    -e "s/NETWORK_UNIT_PLACEHOLDER/${NETWORK_UNIT}/g" \
    -e "s|STORAGE_VOLUME_PLACEHOLDER|${CLUSTER_STORAGE}|g" \
    -e "s|NODE_STORE_PLACEHOLDER|$(node_store "${CONTROL_PLANE_NAME}")|g" \
    -e "s|CONTROL_PLANE_IP_PLACEHOLDER|${CONTROL_PLANE_IP}|g" \
    -e "s/Volume=kinc-etc-kubernetes:/Volume=kinc-${CLUSTER_NAME}-etc-kubernetes:/g" \
    -e "s|CLUSTER_SLICE_PLACEHOLDER|${CLUSTER_SLICE}|g" \
    -e "s|NODE_LIMITS_PLACEHOLDER|${NODE_LIMITS}|g" \
    -e "s/kinc-etc-kubernetes-volume.service/kinc-${CLUSTER_NAME}-etc-kubernetes-volume.service/g" \
    runtime/quadlet/kinc-control-plane.container > ~/.config/containers/systemd/kinc-${CLUSTER_NAME}-control-plane.container

if [ -n "$NODE_ENV" ]; then
    sed -i "/^Environment=KUBECONFIG/a ${NODE_ENV%\\n}" \
        ~/.config/containers/systemd/kinc-${CLUSTER_NAME}-control-plane.container
fi

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

    # Copy the file into the volume path (rootless Podman volume is user-owned)
    cp /tmp/kubeadm-${CLUSTER_NAME}.conf "$VOLUME_PATH/kubeadm.conf"

    # The container mounts this volume with :Z, so under SELinux the file just
    # written needs its context restored. Rootless Podman keeps the volume in
    # the user's own tree, so the user can relabel it without privilege.
    # AppArmor labels nothing, so there is nothing here for it to do.
    if [ "${KINC_MAC:-none}" = "selinux" ] && command -v restorecon >/dev/null 2>&1; then
        echo "🔧 Restoring SELinux context on config volume path..."
        restorecon -R -v "$VOLUME_PATH"
    else
        echo "🔧 Config volume written (kernel MAC: ${KINC_MAC:-none})"
    fi

    rm -f /tmp/kubeadm-${CLUSTER_NAME}.conf
    echo "✅ Cluster configuration volume prepared"
fi


# Step 4: Ensure image is available
echo
echo "🔧 Step 4: Ensuring image is available"
echo "🏗️ Using image: $IMAGE_NAME"

# Check if image is remote (contains registry like ghcr.io, docker.io, quay.io, etc.)
if [[ "$IMAGE_NAME" == ghcr.io/* ]] || [[ "$IMAGE_NAME" == docker.io/* ]] || [[ "$IMAGE_NAME" == quay.io/* ]]; then
    # Remote image - pull if not exists locally
    if ! podman image exists "$IMAGE_NAME"; then
        echo "📥 Pulling remote image..."
        podman pull "$IMAGE_NAME"
    else
        echo "✅ Image already cached locally"
    fi
else
    # Local image - must exist
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
fi

# Step 5: Update container file with cluster-specific settings
echo
echo "🔧 Step 5: Updating container file with cluster-specific settings"
sed -i "s|Image=.*|Image=$IMAGE_NAME|g" ~/.config/containers/systemd/kinc-${CLUSTER_NAME}-control-plane.container
sed -i "s|PublishPort=.*|PublishPort=127.0.0.1:${CLUSTER_PORT}:6443/tcp|g" ~/.config/containers/systemd/kinc-${CLUSTER_NAME}-control-plane.container
sed -i "s|ContainerName=.*|ContainerName=kinc-${CLUSTER_NAME}-control-plane|g" ~/.config/containers/systemd/kinc-${CLUSTER_NAME}-control-plane.container
sed -i "s|HostName=.*|HostName=kinc-${CLUSTER_NAME}-control-plane|g" ~/.config/containers/systemd/kinc-${CLUSTER_NAME}-control-plane.container

# API-server audit logging, when asked for. Each entry is "<group>/<resource>";
# the core group is empty, so "/pods". Unset, the API server starts with no
# audit flags at all and the image is untouched - the same opt-in shape as Faro.
if [[ -n "${KINC_AUDIT_RESOURCES:-}" ]]; then
    echo "🔎 KINC_AUDIT_RESOURCES set - auditing: ${KINC_AUDIT_RESOURCES}"
    sed -i "/^Environment=KUBECONFIG/a Environment=KINC_AUDIT_RESOURCES=${KINC_AUDIT_RESOURCES}" \
        ~/.config/containers/systemd/kinc-${CLUSTER_NAME}-control-plane.container
fi

# Conditionally add Faro environment variable if requested
if [[ "${KINC_ENABLE_FARO:-false}" == "true" ]]; then
    echo "🔍 KINC_ENABLE_FARO=true detected - enabling Faro event capture"
    # Add environment variable to Quadlet file (after existing Environment lines)
    sed -i '/^Environment=KUBECONFIG/a Environment=KINC_ENABLE_FARO=true' ~/.config/containers/systemd/kinc-${CLUSTER_NAME}-control-plane.container
fi

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

# Wait for initialisation to complete. The marker is what says so: it is
# written after postinit succeeds, and kinc-init.service is disabled - the live
# path is kinc-preflight, kubeadm-init, kinc-postinit.
echo "Waiting for cluster initialization to complete..."
max_wait=1500  # 25 minutes max for initialization
waited=0
while [ $waited -lt $max_wait ]; do
    # Check if container is still running
    # Ask podman for the running state directly, rather than grepping a list:
    # grep -q exits on its first match and SIGPIPEs podman, which pipefail
    # turns into a false negative. 'container exists' is not the same check -
    # it is true for a stopped container too.
    running=$(podman container inspect -f '{{.State.Running}}' \
        "kinc-${CLUSTER_NAME}-control-plane" 2>/dev/null || echo false)
    if [ "$running" != "true" ]; then
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
            status=$(podman exec kinc-${CLUSTER_NAME}-control-plane systemctl show -p ActiveState,SubState,Result --value $service | tr '\n' ' ')
            if echo "$status" | grep -qE "(inactive|active) exited success"; then
                echo "✅ $service: completed successfully"
            elif echo "$status" | grep -q "active running"; then
                echo "✅ $service: active"
            else
                echo "❌ $service: $status"
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
    for unit in kinc-preflight kubeadm-init kinc-postinit; do
        podman exec kinc-${CLUSTER_NAME}-control-plane \
            systemctl status ${unit}.service --no-pager || true
        echo
    done
    echo "Recent logs:"
    podman exec kinc-${CLUSTER_NAME}-control-plane journalctl --no-pager -n 100 \
        -u kinc-preflight.service -u kubeadm-init.service -u kinc-postinit.service || true
    exit 1
fi

echo "✅ Cluster initialization completed successfully!"

# ===========================================================================
# Step 8: Join the workers
# ===========================================================================
#
# Each worker is the same image and the same host contract as the control
# plane. What differs is a drop-in that replaces kubeadm-init's ExecStart with
# a join, and a second that makes postinit a no-op - cluster-scoped manifests
# belong to the control plane. The unit's ordering, conditions and success
# marker are shared, because only the command differs.
if [ "$KINC_WORKERS" -gt 0 ]; then
    echo
    echo "👥 Step 8: Joining $KINC_WORKERS worker(s)"

    # One directory per drop-in: systemd applies every .conf in a .d directory,
    # so the two must not share one.
    mkdir -p "${STATE_DIR}/dropins/kubeadm-init" "${STATE_DIR}/dropins/kinc-postinit"
    cp runtime/config/dropins/join.conf "${STATE_DIR}/dropins/kubeadm-init/join.conf"
    cp runtime/config/dropins/postinit.conf "${STATE_DIR}/dropins/kinc-postinit/postinit.conf"

    for i in $(seq 1 "$KINC_WORKERS"); do
        WORKER_NAME="${CLUSTER_NAME}-w${i}"
        WORKER_CONTAINER="kinc-${WORKER_NAME}"
        WORKER_STATE="${STATE_DIR}/${WORKER_NAME}"
        echo
        echo "  ── ${WORKER_CONTAINER}"

        # The join config is complete as written: it carries the endpoint and
        # the CA hash, so this node needs nothing from the control plane's
        # filesystem and waits on its own discovery timeout.
        mkdir -p "${WORKER_STATE}/join"
        sed -e "s/CONTROL_PLANE_ENDPOINT_PLACEHOLDER/${CONTROL_PLANE_ENDPOINT}/g" \
            -e "s/CA_HASH_PLACEHOLDER/${CA_HASH}/g" \
            runtime/config/join.conf > "${WORKER_STATE}/join/join.conf"

        if [ "${KINC_MAC:-none}" = "selinux" ] && command -v restorecon >/dev/null 2>&1; then
            restorecon -R "${WORKER_STATE}" "${STATE_DIR}/dropins" 2>/dev/null || true
        fi

        sed -e "s/kinc-NODE_NAME_PLACEHOLDER/${WORKER_CONTAINER}/g" \
            -e "s/Volume=kinc-var-data:/Volume=${WORKER_CONTAINER}-var-data:/g" \
            -e "s/Volume=kinc-config:/Volume=kinc-${CLUSTER_NAME}-config:/g" \
            -e "s/kinc-var-data-volume.service/${WORKER_CONTAINER}-var-data-volume.service/g" \
            -e "s/kinc-config-volume.service/kinc-${CLUSTER_NAME}-config-volume.service/g" \
            -e "s|JOIN_DIR_PLACEHOLDER|${WORKER_STATE}/join|g" \
            -e "s|JOIN_DROPIN_DIR_PLACEHOLDER|${STATE_DIR}/dropins/kubeadm-init|g" \
            -e "s|POSTINIT_DROPIN_DIR_PLACEHOLDER|${STATE_DIR}/dropins/kinc-postinit|g" \
            -e "s/NETWORK_UNIT_PLACEHOLDER/${NETWORK_UNIT}/g" \
            -e "s|STORAGE_VOLUME_PLACEHOLDER|${CLUSTER_STORAGE}|g" \
            -e "s|NODE_STORE_PLACEHOLDER|$(node_store "${WORKER_CONTAINER}")|g" \
            -e "s|WORKER_IP_PLACEHOLDER|$(get_cluster_node_ip "$CLUSTER_PORT" "$i")|g" \
            -e "s/Volume=kinc-etc-kubernetes:/Volume=${WORKER_CONTAINER}-etc-kubernetes:/g" \
            -e "s|CLUSTER_SLICE_PLACEHOLDER|${CLUSTER_SLICE}|g" \
            -e "s|NODE_LIMITS_PLACEHOLDER|${NODE_LIMITS}|g" \
            -e "s/kinc-etc-kubernetes-volume.service/${WORKER_CONTAINER}-etc-kubernetes-volume.service/g" \
            runtime/quadlet/kinc-worker.container > ~/.config/containers/systemd/${WORKER_CONTAINER}.container
        if [ -n "$NODE_ENV" ]; then
            sed -i "/^Environment=KUBECONFIG/a ${NODE_ENV%\\n}" \
                ~/.config/containers/systemd/${WORKER_CONTAINER}.container
        fi

        sed "s/VolumeName=kinc-var-data/VolumeName=${WORKER_CONTAINER}-var-data/g" \
            runtime/quadlet/kinc-var-data.volume > ~/.config/containers/systemd/${WORKER_CONTAINER}-var-data.volume

        sed "s/VolumeName=kinc-etc-kubernetes/VolumeName=${WORKER_CONTAINER}-etc-kubernetes/g" \
            runtime/quadlet/kinc-etc-kubernetes.volume \
            > ~/.config/containers/systemd/${WORKER_CONTAINER}-etc-kubernetes.volume

        if [[ "${USE_BAKED_IN_CONFIG:-}" == "true" ]]; then
            sed -i '/kinc-config-volume.service/d' ~/.config/containers/systemd/${WORKER_CONTAINER}.container
            sed -i '/Volume=kinc-.*-config:/d' ~/.config/containers/systemd/${WORKER_CONTAINER}.container
        fi

        systemctl --user daemon-reload
        systemctl --user start ${WORKER_CONTAINER}.service
        echo "  ✅ ${WORKER_CONTAINER} started"
    done

    # A node that never joined leaves a cluster-wide check green, so each one is
    # waited for by name. Ready needs the CNI, which Antrea schedules onto the
    # node once it registers.
    echo
    echo "⏳ Waiting for workers to register and become Ready"
    KUBECONFIG_TMP=$(mktemp)
    podman exec ${CONTROL_PLANE_NAME} cat /etc/kubernetes/admin.conf > "$KUBECONFIG_TMP"
    sed -i "s|server: https://.*:6443|server: https://127.0.0.1:${CLUSTER_PORT}|g" "$KUBECONFIG_TMP"

    for i in $(seq 1 "$KINC_WORKERS"); do
        WORKER_CONTAINER="kinc-${CLUSTER_NAME}-w${i}"
        # Registration first, then readiness. 'kubectl wait' on a node that does
        # not exist yet fails immediately with NotFound rather than waiting, so
        # a worker still joining fails the check instead of being waited for.
        registered=false
        for _ in $(seq 1 120); do
            if kubectl --kubeconfig="$KUBECONFIG_TMP" get node "${WORKER_CONTAINER}" >/dev/null 2>&1; then
                registered=true
                break
            fi
            sleep 5
        done
        if [ "$registered" != true ]; then
            echo "❌ ${WORKER_CONTAINER} never registered with the API"
            # kubeadm writes to a file, not the journal, which holds only
            # systemd's own start and stop lines for this unit.
            podman exec ${WORKER_CONTAINER} cat /var/log/kinc/kubeadm-init.log || true
            rm -f "$KUBECONFIG_TMP"
            exit 1
        fi

        if ! kubectl --kubeconfig="$KUBECONFIG_TMP" wait --for=condition=Ready \
             "node/${WORKER_CONTAINER}" --timeout=600s; then
            echo "❌ ${WORKER_CONTAINER} registered but did not become Ready"
            kubectl --kubeconfig="$KUBECONFIG_TMP" describe node "${WORKER_CONTAINER}" || true
            podman exec ${WORKER_CONTAINER} cat /var/log/kinc/kubeadm-init.log || true
            rm -f "$KUBECONFIG_TMP"
            exit 1
        fi

        # Then the agent that gives the node its datapath.
        #
        # A node is Ready once its kubelet sees a usable CNI config, and Antrea
        # writes 10-antrea.conflist from an init container, before the agent
        # container starts. So Ready arrives first: measured at 09:32:43, with
        # the agent starting at 09:32:56. Returning there hands back a worker
        # that answers `kubectl get nodes` and cannot yet move a packet, and
        # whatever runs next puts pods on it.
        #
        # Existence first, then readiness, for the reason above: `kubectl wait`
        # on a selector matching nothing fails rather than waits.
        agent=""
        for _ in $(seq 1 60); do
            agent=$(kubectl --kubeconfig="$KUBECONFIG_TMP" get pod -n kube-system \
                    -l app=antrea,component=antrea-agent \
                    --field-selector "spec.nodeName=${WORKER_CONTAINER}" \
                    -o name 2>/dev/null | head -1)
            [ -n "$agent" ] && break
            sleep 5
        done
        if [ -z "$agent" ]; then
            echo "❌ no antrea-agent was ever scheduled onto ${WORKER_CONTAINER}"
            kubectl --kubeconfig="$KUBECONFIG_TMP" get pod -n kube-system \
                -l app=antrea,component=antrea-agent -o wide || true
            rm -f "$KUBECONFIG_TMP"
            exit 1
        fi
        if ! kubectl --kubeconfig="$KUBECONFIG_TMP" wait --for=condition=Ready \
             "$agent" -n kube-system --timeout=300s; then
            echo "❌ ${WORKER_CONTAINER} is Ready but its antrea-agent is not"
            kubectl --kubeconfig="$KUBECONFIG_TMP" describe "$agent" -n kube-system || true
            rm -f "$KUBECONFIG_TMP"
            exit 1
        fi

        # NodeRestriction refuses every kubernetes.io and k8s.io label a kubelet
        # sets for itself, so the role is applied here, with the cluster's own
        # credentials, after the node has registered.
        kubectl --kubeconfig="$KUBECONFIG_TMP" label node "${WORKER_CONTAINER}" \
            node-role.kubernetes.io/worker= --overwrite >/dev/null
        echo "  ✅ ${WORKER_CONTAINER} Ready, role applied"
    done
    rm -f "$KUBECONFIG_TMP"
    echo "✅ All workers joined"
fi

echo
echo "✅ Deployment complete!"
echo
echo "📋 Next steps:"
echo
echo "  # Extract kubeconfig"
echo "  mkdir -p ~/.kube"
echo "  podman cp kinc-${CLUSTER_NAME}-control-plane:/etc/kubernetes/admin.conf ~/.kube/kinc-${CLUSTER_NAME}-config"
echo "  sed -i 's|server: https://.*:6443|server: https://127.0.0.1:${CLUSTER_PORT}|g' ~/.kube/kinc-${CLUSTER_NAME}-config"
echo
echo "  # Use cluster"
echo "  export KUBECONFIG=~/.kube/kinc-${CLUSTER_NAME}-config"
echo "  kubectl get nodes"
echo "  kubectl get pods -A"
echo
echo "🛑 To stop and cleanup:"
echo "  CLUSTER_NAME=${CLUSTER_NAME} ./tools/cleanup.sh"
