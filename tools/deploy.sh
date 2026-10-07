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
# Derived from the subnet rather than the port, so overriding the subnet moves
# the addresses with it.
get_cluster_node_ip() {
    local index=$1              # index 0 = control plane, 1 = w1, ...
    echo "${NODE_PREFIX}.$(( index + 2 ))"
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
# The node subnet is the one address range that is per MACHINE rather than per
# cluster: a cluster spanning hosts needs a different one on each, while the pod
# and service subnets are cluster-wide and must match everywhere.
#
# Keying it to the port made choosing it mean choosing the published API port -
# two unrelated things, one of them externally visible, and ports below 6443
# compute a negative pod block and are refused outright. KINC_NODE_SUBNET sets
# it directly and leaves the port alone.
CLUSTER_NODE_SUBNET="${KINC_NODE_SUBNET:-$(get_cluster_node_subnet "$CLUSTER_PORT")}"
if [[ ! "$CLUSTER_NODE_SUBNET" =~ ^([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})\.0/24$ ]]; then
    echo "❌ KINC_NODE_SUBNET must be a /24 ending in .0, not '${CLUSTER_NODE_SUBNET}'"
    echo "   each node takes a fixed address in it, so the prefix has to be known"
    exit 1
fi
NODE_PREFIX="${BASH_REMATCH[1]}"
CLUSTER_NODE_GATEWAY="${NODE_PREFIX}.1"
CONTROL_PLANE_IP=$(get_cluster_node_ip 0)

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
# A control plane and a worker are not the same size.
#
# A control plane carries the cluster: its static pods request 650m of CPU
# before anything else - apiserver 250m, controller-manager 200m, etcd 100m,
# scheduler 100m - against a worker's nothing, and both then carry antrea-agent
# at 400m. So a control plane starts 650m further down, and reserves 500m for
# itself against a worker's 200m on top of that.
#
# Splitting a machine evenly therefore gives the control plane far less room
# than the number suggests. Measured on a 4 CPU VM at 2 CPU per node, the
# control plane advertised 1500m and its own pods requested 1450m of it.
#
# KINC_NODE_* applies to every node and is the simple case. The per-role
# variables override it where the split should be weighted, which is most places
# a limit is worth setting at all.
#
#   KINC_NODE_MEMORY=2G             every node
#   KINC_CONTROL_PLANE_MEMORY=3G    this node instead, if set
#   KINC_WORKER_MEMORY=1G           those nodes instead, if set
#
CP_MEMORY="${KINC_CONTROL_PLANE_MEMORY:-${KINC_NODE_MEMORY:-}}"
CP_CPUS="${KINC_CONTROL_PLANE_CPUS:-${KINC_NODE_CPUS:-}}"
WORKER_MEMORY="${KINC_WORKER_MEMORY:-${KINC_NODE_MEMORY:-}}"
WORKER_CPUS="${KINC_WORKER_CPUS:-${KINC_NODE_CPUS:-}}"

# Builds one role's limits and its environment. The node itself knows nothing
# about roles: it reads KINC_NODE_MEMORY, and this passes whichever value that
# role resolved to.
#
#   $1 memory  $2 cpus
# Sets _ROLE_LIMITS and _ROLE_ENV.
build_role_limits() {
    local mem="$1" cpus="$2" _max quota weight
    _ROLE_LIMITS=""
    _ROLE_ENV=""
    if [ -n "$mem" ]; then
        # MemoryHigh is the limit; MemoryMax is a backstop 10% above it.
        # MemoryHigh throttles and reclaims, MemoryMax kills - setting only the
        # kill means a node that drifts over its budget loses a process rather
        # than slowing down, and the kernel picks which.
        _ROLE_LIMITS="MemoryHigh=${mem}"
        _max=$(numfmt --from=iec "${mem%i}" 2>/dev/null) \
            && _ROLE_LIMITS="${_ROLE_LIMITS}\nMemoryMax=$(( _max * 110 / 100 ))"
        # A floor to go with the ceilings. MemoryHigh decides what this node may
        # take; MemoryLow decides what it keeps when the host reclaims, which is
        # the half that makes the number mean anything with several nodes on one
        # machine - the normal case here, since every node is a container on it.
        #
        # Low rather than Min: Min is never reclaimed, so floors that summed past
        # the host's memory would leave the kernel nothing to take and it would
        # OOM instead of shrinking anyone. These values come from the operator,
        # not from the host's size, so nothing here can promise they add up. Low
        # degrades instead - it is honoured while anything else is reclaimable.
        _ROLE_LIMITS="${_ROLE_LIMITS}\nMemoryLow=${mem}"
        _ROLE_ENV="${_ROLE_ENV}Environment=KINC_NODE_MEMORY=${mem}\n"
    fi
    if [ -n "$cpus" ]; then
        quota=$(awk -v c="$cpus" 'BEGIN { printf "%d", c * 100 }')
        _ROLE_LIMITS="${_ROLE_LIMITS:+${_ROLE_LIMITS}\n}CPUQuota=${quota}%"
        # Shares of the shortfall, in the same proportion as the quotas. Without
        # a weight every cgroup sits at the default 100, so a node given one core
        # competes equally with one given four for whatever is contended - the
        # quota caps the top and allocates nothing.
        #
        # Clamped to systemd's 1..10000. IOWeight is the same proportion applied
        # to disk, and is enforced only where the io controller was delegated to
        # the user manager; ci-prepare-host.sh checks for that, because an
        # IOWeight on a unit that has no io controller is accepted and ignored.
        weight=$(awk -v c="$cpus" 'BEGIN { w = int(c * 100); if (w < 1) w = 1; if (w > 10000) w = 10000; print w }')
        _ROLE_LIMITS="${_ROLE_LIMITS}\nCPUWeight=${weight}\nIOWeight=${weight}"
        _ROLE_ENV="${_ROLE_ENV}Environment=KINC_NODE_CPUS=${cpus}\n"
    fi
    # The reserve a node keeps for itself, read inside it and documented as
    # overridable. It reached the node through neither the quadlet nor any
    # PassEnvironment until this was added, so setting either did nothing.
    [ -n "${KINC_NODE_RESERVED_MEMORY:-}" ] && _ROLE_ENV="${_ROLE_ENV}Environment=KINC_NODE_RESERVED_MEMORY=${KINC_NODE_RESERVED_MEMORY}\n"
    [ -n "${KINC_NODE_RESERVED_CPU:-}" ]    && _ROLE_ENV="${_ROLE_ENV}Environment=KINC_NODE_RESERVED_CPU=${KINC_NODE_RESERVED_CPU}\n"
    return 0
}

build_role_limits "$CP_MEMORY" "$CP_CPUS"
NODE_LIMITS="$_ROLE_LIMITS"
NODE_ENV="$_ROLE_ENV"

build_role_limits "$WORKER_MEMORY" "$WORKER_CPUS"
WORKER_NODE_LIMITS="$_ROLE_LIMITS"
WORKER_NODE_ENV="$_ROLE_ENV"

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

echo "🔑 Step 1b: Minting the cluster's shared control-plane material"
mkdir -p "${STATE_DIR}/ca/etcd"

# One authority per thing kubeadm signs with, minted here for the same reason
# the cluster CA is: material that exists before any node does can be handed to
# a joining control plane directly.
#
# The alternative kubeadm offers is --upload-certs, which puts this set in a
# Secret encrypted with a certificate key. That Secret expires two hours after
# it is written, so a control plane joined on day two needs someone to go and
# re-upload it first - the same ordering problem the pre-minted CA removed, in
# a different place. Material on disk does not expire.
#
# All four have to be identical on every control plane: sa.key signs service
# account tokens, and the two extra CAs sign the aggregation layer and etcd's
# peer certificates. A control plane that minted its own would issue tokens and
# peer certificates the others reject.
mint_ca() { # <path-prefix> <CN>
    [ -f "$1.crt" ] && [ -f "$1.key" ] && return 0
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -subj "/CN=$2" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign,digitalSignature" \
        -keyout "$1.key" -out "$1.crt" 2>/dev/null || return 1
    chmod 0600 "$1.key"
    return 0
}

if [ -f "${STATE_DIR}/ca/ca.crt" ] && [ -f "${STATE_DIR}/ca/ca.key" ] \
   && [ -f "${STATE_DIR}/ca/sa.key" ]; then
    echo "✅ Reusing the material already minted for cluster '${CLUSTER_NAME}'"
else
    mint_ca "${STATE_DIR}/ca/ca"              "kubernetes"     || { echo "❌ could not mint the cluster CA"; exit 1; }
    mint_ca "${STATE_DIR}/ca/front-proxy-ca"  "front-proxy-ca" || { echo "❌ could not mint the front-proxy CA"; exit 1; }
    mint_ca "${STATE_DIR}/ca/etcd/ca"         "etcd-ca"        || { echo "❌ could not mint the etcd CA"; exit 1; }
    # Not a certificate: a keypair kube-controller-manager signs service account
    # tokens with and the API server verifies them against.
    if [ ! -f "${STATE_DIR}/ca/sa.key" ]; then
        openssl genrsa -out "${STATE_DIR}/ca/sa.key" 2048 2>/dev/null \
            && openssl rsa -in "${STATE_DIR}/ca/sa.key" -pubout \
                   -out "${STATE_DIR}/ca/sa.pub" 2>/dev/null \
            || { echo "❌ could not mint the service account keypair"; exit 1; }
        chmod 0600 "${STATE_DIR}/ca/sa.key"
    fi
    echo "✅ Minted: cluster CA, front-proxy CA, etcd CA, service account keypair"
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
# NODE_ENV and WORKER_NODE_ENV are built per role above, by build_role_limits.

# The cluster's cgroup. Written whether or not it carries limits, so every
# node of a cluster is grouped under one slice and `systemd-cgls` shows a
# cluster as a cluster.
mkdir -p ~/.config/systemd/user
sed "s|CLUSTER_LIMITS_PLACEHOLDER|${CLUSTER_LIMITS}|" \
    runtime/quadlet/kinc-cluster.slice > ~/.config/systemd/user/${CLUSTER_SLICE}
if [ -n "$CLUSTER_LIMITS" ]; then
    echo "🧮 Cluster limits: $(printf '%b' "$CLUSTER_LIMITS" | tr '\n' ' ')"
fi
# Per role, and both of them, because they can differ.
#
# This printed NODE_LIMITS alone, which is the control plane's. On a weighted
# split that reported one role's limits as though they applied to every node and
# never mentioned the worker's at all - so a wrong worker figure had nothing to
# survive on its way past. A success path that does not say what it did is how
# every silent no-op in this repo stayed silent.
if [ -n "$NODE_LIMITS" ] || [ -n "$WORKER_NODE_LIMITS" ]; then
    if [ "$NODE_LIMITS" = "$WORKER_NODE_LIMITS" ]; then
        echo "🧮 Per-node limits: $(printf '%b' "$NODE_LIMITS" | tr '\n' ' ')"
    else
        echo "🧮 Control plane:   $(printf '%b' "${NODE_LIMITS:-<unlimited>}" | tr '\n' ' ')"
        if [ "${KINC_WORKERS:-0}" -gt 0 ]; then
            echo "🧮 Each worker:     $(printf '%b' "${WORKER_NODE_LIMITS:-<unlimited>}" | tr '\n' ' ')"
        fi
    fi
fi

# What kubeadm wrote about this node, so a restart comes back as the same node.
sed "s/VolumeName=kinc-etc-kubernetes/VolumeName=kinc-${CLUSTER_NAME}-etc-kubernetes/g" \
    runtime/quadlet/kinc-etc-kubernetes.volume \
    > ~/.config/containers/systemd/kinc-${CLUSTER_NAME}-etc-kubernetes.volume

# Multi-host knobs. All are unset for a single-machine cluster, and then every
# placeholder below renders empty and the quadlet is what it always was.
#
#   KINC_API_BIND        address the API server is published on (default loopback)
#   KINC_WG_DIR          this node's WireGuard material: private, address, peers
#   KINC_ADVERTISE       file holding the endpoint a joining node dials
#   KINC_API_EXTRA_SANS  file of further API server names, one per line
#   KINC_NODE_SUBNET     the /24 this machine's node containers sit on
#
# Only the control plane publishes a WireGuard port; the quadlet says why a
# worker must not.
API_BIND="${KINC_API_BIND:-127.0.0.1}"
WG_VOLUME=""
WG_PUBLISH=""
ADVERTISE_VOLUME=""
if [ -n "${KINC_WG_DIR:-}" ]; then
    WG_VOLUME="Volume=${KINC_WG_DIR}:/etc/kinc/wg:ro,Z"
    WG_PUBLISH="PublishPort=0.0.0.0:${KINC_WG_PORT:-51820}:${KINC_WG_PORT:-51820}/udp"
fi
if [ -n "${KINC_ADVERTISE:-}" ]; then
    ADVERTISE_VOLUME="Volume=${KINC_ADVERTISE}:/etc/kinc/advertise-addr:ro,Z"
fi
EXTRA_SANS_VOLUME=""
if [ -n "${KINC_API_EXTRA_SANS:-}" ]; then
    EXTRA_SANS_VOLUME="Volume=${KINC_API_EXTRA_SANS}:/etc/kinc/extra-sans:ro,Z"
fi

# Copy and customize container file
sed -e "s/ContainerName=kinc-control-plane/ContainerName=kinc-${CLUSTER_NAME}-control-plane/g" \
    -e "s/HostName=kinc-control-plane/HostName=kinc-${CLUSTER_NAME}-control-plane/g" \
    -e "s/Volume=kinc-var-data:/Volume=kinc-${CLUSTER_NAME}-var-data:/g" \
    -e "s/Volume=kinc-config:/Volume=kinc-${CLUSTER_NAME}-config:/g" \
    -e "s/kinc-var-data-volume.service/kinc-${CLUSTER_NAME}-var-data-volume.service/g" \
    -e "s/kinc-config-volume.service/kinc-${CLUSTER_NAME}-config-volume.service/g" \
    -e "s/PublishPort=127.0.0.1:6443:6443\/tcp/PublishPort=127.0.0.1:${CLUSTER_PORT}:6443\/tcp/g" \
    -e "s|CA_DIR_PLACEHOLDER|${STATE_DIR}/ca|g" \
    -e "s|API_BIND_PLACEHOLDER|${API_BIND}|g" \
    -e "s|WG_VOLUME_PLACEHOLDER|${WG_VOLUME}|g" \
    -e "s|WG_PUBLISH_PLACEHOLDER|${WG_PUBLISH}|g" \
    -e "s|ADVERTISE_VOLUME_PLACEHOLDER|${ADVERTISE_VOLUME}|g" \
    -e "s|EXTRA_SANS_VOLUME_PLACEHOLDER|${EXTRA_SANS_VOLUME}|g" \
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
# Anchored on the ":6443/tcp" suffix, which is the API server's line and
# nothing else. Left as "PublishPort=.*" this rewrites every published port
# the quadlet carries, so a cluster that also publishes a WireGuard port
# silently loses it here. The anchor has to tolerate the unsubstituted
# CLUSTER_PORT placeholder, because this line is what replaces it.
sed -i "s|^PublishPort=.*:6443/tcp$|PublishPort=${API_BIND}:${CLUSTER_PORT}:6443/tcp|" ~/.config/containers/systemd/kinc-${CLUSTER_NAME}-control-plane.container
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
    # deploy.sh creates workers only; a control plane is joined by join-host.sh,
    # which renders the same drop-in with the extra phase it has to skip.
    sed "s|JOIN_SKIP_PHASES_PLACEHOLDER|preflight|" \
        runtime/config/dropins/join.conf > "${STATE_DIR}/dropins/kubeadm-init/join.conf"
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
        # A local worker's node-ip is its address on the cluster's podman
        # network - the same one the quadlet pins. join.conf has always carried
        # a placeholder for this that nothing replaced, so the kubelet fell back
        # to its default route address; on one machine that is the same address,
        # which is why the gap was invisible.
        WORKER_NODE_IP="$(get_cluster_node_ip "$i")"
        sed -e "s/CONTROL_PLANE_ENDPOINT_PLACEHOLDER/${CONTROL_PLANE_ENDPOINT}/g" \
            -e "s/CA_HASH_PLACEHOLDER/${CA_HASH}/g" \
            -e "s/CONTAINER_IP_PLACEHOLDER/${WORKER_NODE_IP}/g" \
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
            -e "s|WORKER_IP_PLACEHOLDER|${WORKER_NODE_IP}|g" \
            -e "s|WG_VOLUME_PLACEHOLDER||g" \
            -e "s|CA_VOLUME_PLACEHOLDER||g" \
            -e "s/Volume=kinc-etc-kubernetes:/Volume=${WORKER_CONTAINER}-etc-kubernetes:/g" \
            -e "s|CLUSTER_SLICE_PLACEHOLDER|${CLUSTER_SLICE}|g" \
            -e "s|NODE_LIMITS_PLACEHOLDER|${WORKER_NODE_LIMITS}|g" \
            -e "s/kinc-etc-kubernetes-volume.service/${WORKER_CONTAINER}-etc-kubernetes-volume.service/g" \
            runtime/quadlet/kinc-worker.container > ~/.config/containers/systemd/${WORKER_CONTAINER}.container
        if [ -n "$WORKER_NODE_ENV" ]; then
            sed -i "/^Environment=KUBECONFIG/a ${WORKER_NODE_ENV%\\n}" \
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

# Converged, not merely initialised.
#
# Step 7 waits for /var/lib/kinc-initialized, which kinc-postinit writes. On a
# first boot that is the right signal and the cluster is fully up by the time it
# appears. On a resume it is not a signal at all: the marker is on a volume and
# postinit is gated on it, so the wait returns at once and this declared the
# deployment complete while a pod was still being created. Measured: a resumed
# cluster exited here after 20s with one container still creating.
#
# So the check is on content rather than on a unit or a marker, which is what
# holds on both paths - the same reasoning as kinc-check-state keying on
# ca.crt rather than on a volume existing. CoreDNS is the addon worth waiting
# for: it being Available means the CNI carries pod traffic, the scheduler
# placed it, and DNS answers, which is what "usable" means to whatever runs
# next.
#
# Nodes being Ready is deliberately not the signal. A kubelet reports Ready once
# it sees a usable CNI config, which precedes the addons being up, and "nodes
# Ready therefore cluster usable" is a trap two separate consumers have fallen
# into from opposite directions.
_wait_converged() {
    local kc timeout=120
    kc=$(mktemp)
    podman exec "kinc-${CLUSTER_NAME}-control-plane" cat /etc/kubernetes/admin.conf > "$kc" 2>/dev/null
    sed -i "s|server: https://.*:6443|server: https://127.0.0.1:${CLUSTER_PORT}|g" "$kc"
    if kubectl --kubeconfig="$kc" wait --for=condition=Available \
           --timeout="${timeout}s" -n kube-system deploy/coredns >/dev/null 2>&1; then
        echo "✅ Addons converged (CoreDNS available)"
    else
        # Said rather than swallowed: the cluster may still be usable, and the
        # caller is about to run kubectl against it either way.
        echo "⚠️  CoreDNS did not become available within ${timeout}s"
        echo "   The cluster is up but its addons are still converging; check with"
        echo "   kubectl get pods -A before relying on DNS or scheduling."
    fi
    rm -f "$kc"
}
_wait_converged

echo
echo "✅ Deployment complete!"

# What each node actually reserved, read from the node rather than derived here.
#
# Deriving it host-side would be a prediction, and a prediction that silently
# disagreed with the node would print a confident wrong number - which is the
# failure this codebase keeps producing. It would also put the reserve defaults
# in two places, free to drift.
#
# The node resolves them and writes them down, so this reads what it wrote. The
# same file is what the kubelet reads, so there is nothing between this and the
# behaviour. For a consumer who mounts /etc/kubernetes it is readable from
# outside the node for the same reason.
_resolved_reservations() {
    local n first=1 dropin=/etc/kubernetes/kubelet.conf.d/20-kinc-node-resources.conf
    for n in $(podman ps --format '{{.Names}}' 2>/dev/null | grep "^kinc-${CLUSTER_NAME}-" | sort); do
        podman exec "$n" test -f "$dropin" 2>/dev/null || continue
        if [ "$first" -eq 1 ]; then
            echo
            echo "🧮 Reserved by each node, as the node resolved it:"
            first=0
        fi
        # `cat` inside the container, not a redirection outside it: `< "$dropin"`
        # is resolved by this shell, on the host, where the file does not exist.
        # That printed an empty value under a confident header, which is the
        # failure this whole function exists to prevent.
        _r=$(podman exec "$n" cat "$dropin" 2>/dev/null | tr -d ' ' \
             | awk -F: '/^(systemReserved|kubeReserved)/ { k=$1 }
                        /^(cpu|memory)/ { printf "%s.%s=%s ", k, $1, $2 }')
        printf '   %-30s %s\n' "$n" "${_r:-<could not read ${dropin}>}"
    done
}
_resolved_reservations
echo
echo "📋 Next steps:"
echo
# admin.conf names the control plane's own hostname, which resolves only inside
# the cluster network, so the server is rewritten to something the client can
# reach. Loopback and the published port is right for a client on this machine
# and wrong for every other one, and a cluster reached through a name or a
# load-balanced address is told so here rather than hand-edited afterwards.
KUBECONFIG_SERVER="${KINC_KUBECONFIG_SERVER:-127.0.0.1:${CLUSTER_PORT}}"
echo "  # Extract kubeconfig"
echo "  mkdir -p ~/.kube"
echo "  podman cp kinc-${CLUSTER_NAME}-control-plane:/etc/kubernetes/admin.conf ~/.kube/kinc-${CLUSTER_NAME}-config"
echo "  sed -i 's|server: https://.*:6443|server: https://${KUBECONFIG_SERVER}|g' ~/.kube/kinc-${CLUSTER_NAME}-config"
echo
echo "  # Use cluster"
echo "  export KUBECONFIG=~/.kube/kinc-${CLUSTER_NAME}-config"
echo "  kubectl get nodes"
echo "  kubectl get pods -A"
echo
echo "🛑 To stop and cleanup:"
echo "  CLUSTER_NAME=${CLUSTER_NAME} ./tools/cleanup.sh"
