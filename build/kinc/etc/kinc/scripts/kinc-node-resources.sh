#!/usr/bin/env bash
# Render this node's resource reservations into the kubelet's config directory.
#
# Runs on every boot, which is the whole point. kinc-preflight.service and
# kubeadm-init.service are both gated on ConditionPathExists=!/var/lib/kubeadm-initialized,
# and /var is a volume while /etc/kinc is not - so on a cluster that comes back,
# neither runs, and anything they configured is frozen at whatever version and
# whatever environment first built it.
#
# That made the resource feature half-work on a resumed cluster, which is worse
# than not working: KINC_NODE_MEMORY is read by deploy.sh when it renders the
# quadlet, so the unit-level MemoryHigh and CPUQuota were applied, while the
# systemReserved that makes the kubelet advertise honestly was computed here and
# written somewhere only a first boot reads. The cgroup refused what the
# scheduler kept placing. Measured in the wild: limits enforced at 3.5G, and the
# node still offering 7.7Gi of a 8G machine.
#
# The kubelet reads /var/lib/kubelet/config.yaml, which kubeadm owns and
# rewrites - on init, and again on join from the kubelet-config ConfigMap the
# control plane uploaded. A drop-in under --config-dir is applied over that
# file, so it survives both, which is also why this replaces the join patch
# directory that used to carry a worker's reserve.
set -euo pipefail

DROPIN_DIR=/etc/kubernetes/kubelet.conf.d
DROPIN="${DROPIN_DIR}/20-kinc-node-resources.conf"

log() { echo "[kinc-node-resources] $*"; }

# Nothing asked for means nothing reserved, and that has to be able to take
# effect on a cluster that previously had a limit. Leaving the last render in
# place would be the same freezing bug one level down: a cluster would carry a
# reserve nobody asked for and no way to clear it.
if [[ -z "${KINC_NODE_MEMORY:-}${KINC_NODE_CPUS:-}" ]]; then
    if [[ -f "$DROPIN" ]]; then
        rm -f "$DROPIN"
        log "no node limits asked for; removed the previous reservation"
    fi
    exit 0
fi

install -d -m 0755 "$DROPIN_DIR"

# systemd's K/M/G are 1024-based and Kubernetes writes Ki/Mi/Gi for the same
# thing, so kinc takes either. numfmt does not: --from=iec rejects the "i"
# outright, and --from=auto reads a bare "4G" as 4,000,000,000, which would
# leave the reserve disagreeing with the cgroup limit by 7% in silence.
#
# The suffix is upper-cased because podman spells the same quantity "8g", and
# that is what someone writing a quadlet by hand reaches for. numfmt rejects it,
# and the caller below used to carry on with an empty result - the node then
# reserved CPU, reserved no memory at all, and advertised every byte the machine
# had. Taking either spelling costs one expansion.
bytes_of() { local _v="${1^^}"; numfmt --from=iec "${_v%I}" 2>/dev/null; }

# What this node needs to be a node, before any pod is scheduled. Measured idle
# on an empty cluster: a control plane's cgroup held 2956MiB and a worker's
# 1231MiB, and a static pod has no memory request, so the scheduler cannot see
# any of it. A node that does not subtract this advertises memory it is already
# using.
if [[ -f /etc/kinc/join/join.conf ]]; then
    _RESERVE_MEM="${KINC_NODE_RESERVED_MEMORY:-1Gi}"
    _RESERVE_CPU="${KINC_NODE_RESERVED_CPU:-200m}"
else
    _RESERVE_MEM="${KINC_NODE_RESERVED_MEMORY:-2Gi}"
    _RESERVE_CPU="${KINC_NODE_RESERVED_CPU:-500m}"
fi

_SYS_MEM_KI=""; _KUBE_MEM_KI=""; _SYS_CPU=""; _KUBE_CPU=""

if [[ -n "${KINC_NODE_MEMORY:-}" ]]; then
    _total_kb=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
    # A value numfmt cannot read is a mistake in the spec, not a reason to go on.
    # This used to fall through to the "not below this machine's NNNNMi" warning
    # below, which is a true statement about a different problem: it sends the
    # reader to check the size of a figure whose spelling is what was wrong, and
    # the node comes up having reserved nothing.
    _limit_b=$(bytes_of "${KINC_NODE_MEMORY}") || :
    [[ -n "$_limit_b" ]] || {
        log "❌ KINC_NODE_MEMORY=${KINC_NODE_MEMORY} is not a quantity this can read"
        log "   Write it as 8G, 8g or 8Gi - a plain number of bytes also works."
        exit 1; }
    _kube_b=$(bytes_of "${_RESERVE_MEM}") || :
    [[ -n "$_kube_b" ]] || {
        log "❌ KINC_NODE_RESERVED_MEMORY=${_RESERVE_MEM} is not a quantity this can read"
        exit 1; }
    _limit_kb=$(( _limit_b / 1024 ))
    _kube_kb=$(( _kube_b / 1024 ))
    if (( _limit_kb > 0 && _limit_kb < _total_kb )); then
        if (( _kube_kb >= _limit_kb )); then
            log "❌ ${_RESERVE_MEM} is reserved for this node's own components but the node is limited to ${KINC_NODE_MEMORY}"
            log "   Nothing would be left to schedule. Raise KINC_NODE_MEMORY or lower KINC_NODE_RESERVED_MEMORY."
            exit 1
        fi
        _SYS_MEM_KI="$(( _total_kb - _limit_kb ))Ki"
        _KUBE_MEM_KI="${_kube_kb}Ki"
        log "memory: ${KINC_NODE_MEMORY} of $(( _total_kb / 1024 ))Mi, less ${_RESERVE_MEM} for the node itself"
        log "   → allocatable $(( (_limit_kb - _kube_kb) / 1024 ))Mi"
    else
        log "⚠️  KINC_NODE_MEMORY=${KINC_NODE_MEMORY} is not below this machine's $(( _total_kb / 1024 ))Mi; nothing reserved"
    fi
fi

if [[ -n "${KINC_NODE_CPUS:-}" ]]; then
    _total_cpu=$(nproc)
    # Two different reserves, and they were one.
    #
    # systemReserved is what the OTHER nodes on this machine take: the machine
    # has nproc, this node was given KINC_NODE_CPUS, the difference belongs to
    # its neighbours. kubeReserved is what THIS node's own kubelet and runtime
    # need. They are independent, and tying the second to the first made a node
    # that is alone on its machine advertise every core it had - nproc equals
    # KINC_NODE_CPUS there, so the difference is zero, and the node's own reserve
    # was dropped along with the neighbours' share. Measured on two single-node
    # VMs: both advertised their whole CPUQuota as schedulable, leaving the
    # kubelet and CRI-O to compete with pods for cores already promised away.
    _reserved=$(awk -v t="$_total_cpu" -v c="${KINC_NODE_CPUS}" 'BEGIN { r = t - c; print (r > 0 ? r : 0) }')
    if [[ "$_reserved" != "0" ]]; then
        _SYS_CPU="$_reserved"
    fi
    # Refused rather than applied: a reserve at or above the node's own limit
    # leaves nothing to schedule, which is the memory path's rule and was not
    # the cpu path's.
    if awk -v r="${_RESERVE_CPU%m}" -v rm="${_RESERVE_CPU}" -v c="${KINC_NODE_CPUS}" \
        'BEGIN { res = (rm ~ /m$/) ? r/1000 : r; exit !(res >= c) }'; then
        log "❌ ${_RESERVE_CPU} is reserved for this node's own components but the node is limited to ${KINC_NODE_CPUS}"
        log "   Nothing would be left to schedule. Raise KINC_NODE_CPUS or lower KINC_NODE_RESERVED_CPU."
        exit 1
    fi
    _KUBE_CPU="${_RESERVE_CPU}"
    log "cpu: ${KINC_NODE_CPUS} of ${_total_cpu}, less ${_RESERVE_CPU} for the node itself"
    [[ -z "$_SYS_CPU" ]] && log "   alone on this machine: nothing reserved for neighbours"
fi

# Everything asked for was above this machine's size, so there is nothing to
# reserve and any previous render must still go.
if [[ -z "${_SYS_MEM_KI}${_SYS_CPU}${_KUBE_CPU}" ]]; then
    rm -f "$DROPIN"
    exit 0
fi

# Written whole and moved, so a kubelet starting concurrently reads either the
# previous render or this one, never half of one.
tmp="${DROPIN}.tmp"
{
    echo "apiVersion: kubelet.config.k8s.io/v1beta1"
    echo "kind: KubeletConfiguration"
    if [[ -n "${_SYS_CPU}${_SYS_MEM_KI}" ]]; then
        echo "systemReserved:"
        [[ -n "$_SYS_CPU" ]]    && echo "  cpu: \"${_SYS_CPU}\""
        [[ -n "$_SYS_MEM_KI" ]] && echo "  memory: \"${_SYS_MEM_KI}\""
    fi
    echo "kubeReserved:"
    [[ -n "$_KUBE_CPU" ]]   && echo "  cpu: \"${_KUBE_CPU}\""
    [[ -n "$_KUBE_MEM_KI" ]] && echo "  memory: \"${_KUBE_MEM_KI}\""
} > "$tmp"
mv -f "$tmp" "$DROPIN"
log "wrote ${DROPIN}"
