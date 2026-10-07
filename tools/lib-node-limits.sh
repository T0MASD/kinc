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
