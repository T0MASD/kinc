#!/usr/bin/env bash
# How a node's size becomes systemd directives and the node's own environment.
#
# Shared because both halves of a cluster need it and they used to disagree:
# deploy.sh sized the nodes it created and join-host.sh sized nothing, so a node
# joined from another machine advertised that machine's whole capacity whatever
# it had been given. One copy, sourced by both.
#
# shellcheck shell=bash

# Builds one role's limits and its environment. The node itself knows nothing
# about roles: it reads KINC_NODE_MEMORY, and this passes whichever value that
# role resolved to.
#
#   $1 memory  $2 cpus
# Sets _ROLE_LIMITS and _ROLE_ENV.
# The node checks this too, and refuses - but by then the cluster is built, the
# failure is inside kinc-node-resources.service, and NOTHING DEPENDS ON THAT
# UNIT SUCCEEDING. Before=kubelet.service only orders; it does not require. So
# the kubelet starts anyway, the node runs with no reservations at all, and
# deploy.sh reports success. The error is in a journal nobody opens.
#
# Checking here fails before anything is built, while the operator is still
# looking at the terminal.
#
# bytes_of is copied verbatim from kinc-node-resources.sh on purpose: a
# pre-flight that disagrees with the runtime check is worse than no pre-flight.
_bytes_of() { local _v="${1^^}"; numfmt --from=iec "${_v%I}" 2>/dev/null; }

# $1 the role's memory limit ("" = derived, nothing to check)
# $2 the reserve this node will apply if KINC_NODE_RESERVED_MEMORY is unset
# $3 a label for the message
check_reservation_fits() {
    local mem="$1" fallback="$2" label="$3" reserve limit_b res_b
    [ -n "$mem" ] || return 0
    reserve="${KINC_NODE_RESERVED_MEMORY:-$fallback}"
    # A value the node cannot read is refused by the node too, with the same
    # result as a reserve that does not fit: no reservations at all. Refuse it
    # here instead of letting it through.
    limit_b=$(_bytes_of "$mem") || :
    [ -n "$limit_b" ] || {
        echo "❌ ${label}: memory limit '${mem}' is not a quantity the node can read." >&2
        echo "   Write it as 8G, 8g or 8Gi - a plain number of bytes also works." >&2
        return 1; }
    res_b=$(_bytes_of "$reserve") || :
    [ -n "$res_b" ] || {
        echo "❌ ${label}: KINC_NODE_RESERVED_MEMORY='${reserve}' is not a quantity the node can read." >&2
        return 1; }
    if [ "$res_b" -ge "$limit_b" ]; then
        echo "❌ ${label}: ${reserve} is reserved for the node's own components," >&2
        echo "   but the node is limited to ${mem}. Nothing would be left to schedule." >&2
        echo "   Raise the memory limit or lower KINC_NODE_RESERVED_MEMORY." >&2
        echo "   (left unchecked the node starts anyway, with NO reservations at all)" >&2
        return 1
    fi
}

# The same rule for CPU, as kinc-node-resources.sh applies it: a reserve in
# millicores ("500m") or cores ("1"), refused when it is at or above the node's
# CPU limit. An unreadable limit is refused too, and here it MUST be: the node
# does not catch one - its awk compares "abc" as a string, the check passes, and
# the node reserves the whole machine for its neighbours - while the quadlet
# would get CPUQuota=0%.
#   $1 the role's CPU limit ("" = derived)  $2 the default reserve  $3 a label
check_cpu_reservation_fits() {
    local cpus="$1" fallback="$2" label="$3" reserve
    [ -n "$cpus" ] || return 0
    reserve="${KINC_NODE_RESERVED_CPU:-$fallback}"
    [[ "$cpus" =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v c="$cpus" 'BEGIN { exit !(c > 0) }' || {
        echo "❌ ${label}: CPU limit '${cpus}' is not a positive number of cores." >&2
        return 1; }
    [[ "$reserve" =~ ^[0-9]+([.][0-9]+)?m?$ ]] || {
        echo "❌ ${label}: KINC_NODE_RESERVED_CPU='${reserve}' is not cores or millicores." >&2
        return 1; }
    if awk -v r="${reserve%m}" -v rm="$reserve" -v c="$cpus" \
        'BEGIN { res = (rm ~ /m$/) ? r/1000 : r; exit !(res >= c) }'; then
        echo "❌ ${label}: ${reserve} CPU is reserved for the node's own components," >&2
        echo "   but the node is limited to ${cpus}. Nothing would be left to schedule." >&2
        echo "   Raise the CPU limit or lower KINC_NODE_RESERVED_CPU." >&2
        echo "   (left unchecked the node starts anyway, with NO reservations at all)" >&2
        return 1
    fi
}

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
