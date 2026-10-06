#!/usr/bin/env bash
#
# Assert that what was asked for is what is enforced, and what is advertised.
#
# Usage: KINC_NODE_MEMORY=4G KINC_NODE_CPUS=2 ./tools/ci-verify-node-resources.sh [cluster]
#
# Three separate things have to agree, and each has silently failed on its own
# while the other two looked right:
#
#   asked      the environment deploy.sh was given
#   enforced   the cgroup, via the node's systemd unit and the cluster's slice
#   advertised allocatable, which is the only one the scheduler places against
#
# A limit with no reserve advertises memory the node is already using. A reserve
# with no limit bounds nothing. A slice written where quadlet does not read it
# is accepted and ignored. A worker whose kubelet config is downloaded from the
# cluster gets the control plane's reserve and not its own. Every one of those
# passed a "did the deploy succeed" check.
#
# With nothing asked for, it asserts the opposite: no limits anywhere, because
# unlimited is the default and a default that quietly changed would be worse
# than a limit that quietly failed.
set -euo pipefail

CLUSTER="${1:-default}"
CP="kinc-${CLUSTER}-control-plane"
SLICE="kinc-${CLUSTER}.slice"
status=0

say()  { printf '   %s\n' "$*"; }
fail() { printf '❌ %s\n' "$*"; status=1; }
ok()   { printf '✅ %s\n' "$*"; }

# Kubernetes quantities and systemd sizes, both to bytes. kinc reads G and Gi
# alike as binary, matching systemd; Kubernetes writes Ki/Mi/Gi for the same.
bytes() {
    local v="${1:-0}"
    case "$v" in
        infinity|max|"") echo -1 ;;
        *[0-9]) echo "$v" ;;
        *) numfmt --from=iec "${v%i}" 2>/dev/null || echo -1 ;;
    esac
}
# 1500m -> 1.5, 2 -> 2
cores() { awk -v v="${1:-0}" 'BEGIN { if (v ~ /m$/) { sub(/m$/, "", v); print v/1000 } else print v+0 }'; }

# The kernel's own copy of a unit's limits. systemctl show reports what systemd
# intends, which is not the same thing: a controller that was never delegated
# makes systemd accept a setting the kernel never receives, and show still
# repeats it back. Reading the cgroup is what distinguishes configured from
# enforced, and it is the only way to catch the io case at all.
cgfile() {
    local unit="$1" file="$2" rel
    rel=$(systemctl --user show "$unit" -p ControlGroup --value 2>/dev/null)
    [ -n "$rel" ] || return 1
    cat "/sys/fs/cgroup${rel}/${file}" 2>/dev/null
}

nodes=$(podman ps --format '{{.Names}}' | grep "^kinc-${CLUSTER}-" | sort)
[ -n "$nodes" ] || { echo "❌ no nodes running for cluster '${CLUSTER}'"; exit 1; }

KUBECONFIG_FILE=$(mktemp); trap 'rm -f "$KUBECONFIG_FILE"' EXIT
port=$(podman inspect "$CP" --format '{{range $p, $c := .NetworkSettings.Ports}}{{range $c}}{{.HostPort}}{{end}}{{end}}' | head -1)
podman exec "$CP" cat /etc/kubernetes/admin.conf 2>/dev/null \
    | sed "s|server: https://.*:6443|server: https://127.0.0.1:${port:-6443}|" > "$KUBECONFIG_FILE"
kc() { KUBECONFIG="$KUBECONFIG_FILE" kubectl "$@"; }

echo "=== ${CLUSTER}: node resources ==="

# --- the pod pid limit ------------------------------------------------------
# Unconditional, because it is not something the operator asks for: it ships in
# the KubeletConfiguration and applies to every cluster. Checked before the
# "nothing was asked for" exit below, which returns early.
#
# Asserted on a pod's cgroup rather than on the config that produced it. kubeadm
# owns /var/lib/kubelet/config.yaml and rewrites it, so the file the kubelet
# reads is not the file this repo ships - a value that never survived into the
# cluster's kubelet-config would still be present in the source and absent from
# every node.
want_pids=4096
for n in $nodes; do
    # The pod's cgroup, not a container's inside it. podPidsLimit is applied to
    # the pod sandbox; the container cgroups below it carry no limit of their own
    # and read "max" while inheriting the pod's. Reading one of those reports an
    # unlimited pod on a cluster where the limit is working perfectly, which is
    # what the first version of this check did.
    pm=$(podman exec "$n" sh -c '
        find /sys/fs/cgroup/kubepods* -name pids.max -path "*/pod*" \
             ! -path "*/crio-*" 2>/dev/null | head -1' 2>/dev/null)
    if [ -z "$pm" ]; then
        fail "${n}: no pod cgroup carrying pids.max - podPidsLimit cannot be confirmed"
        continue
    fi
    got=$(podman exec "$n" cat "$pm" 2>/dev/null)
    [ "$got" = "$want_pids" ] \
        && ok "${n}: pods capped at pids.max=${got}" \
        || fail "${n}: pod pids.max is ${got:-unreadable} at ${pm}, expected ${want_pids} from podPidsLimit"
done

# --- nothing asked for: assert nothing was done ---------------------------
# Every variable that asks for something, including the per-role ones. Leaving
# those out of this guard sent a weighted cluster down the "nothing was asked
# for" path, where it asserted the absence of the limits it had just been given.
if [ -z "${KINC_NODE_MEMORY:-}${KINC_NODE_CPUS:-}${KINC_CLUSTER_MEMORY:-}${KINC_CLUSTER_CPUS:-}${KINC_CONTROL_PLANE_MEMORY:-}${KINC_CONTROL_PLANE_CPUS:-}${KINC_WORKER_MEMORY:-}${KINC_WORKER_CPUS:-}" ]; then
    for n in $nodes; do
        for prop in MemoryHigh MemoryMax; do
            v=$(systemctl --user show "${n}.service" -p "$prop" --value)
            [ "$v" = "infinity" ] || fail "${n}: ${prop}=${v}, but no limit was asked for"
        done
        q=$(systemctl --user show "${n}.service" -p CPUQuotaPerSecUSec --value)
        [ "$q" = "infinity" ] || fail "${n}: CPUQuota=${q}, but no limit was asked for"
        # The floors and weights have defaults of their own, and a default that
        # quietly changed would be as wrong as a limit that quietly failed.
        low=$(cgfile "${n}.service" memory.low || echo 0)
        [ "${low:-0}" = "0" ] || fail "${n}: memory.low=${low}, but no floor was asked for"
        w=$(cgfile "${n}.service" cpu.weight || echo 100)
        [ "${w:-100}" = "100" ] || fail "${n}: cpu.weight=${w}, but no weight was asked for"
    done
    [ "$status" -eq 0 ] && ok "${CLUSTER}: unlimited, as asked"
    exit "$status"
fi

# What a given node was asked for. KINC_NODE_* applies to every node; the
# per-role variables override it, and a weighted split is the normal case once a
# limit is worth setting - a control plane's static pods request 650m before
# anything else, so an even split leaves it with far less room than a worker.
#
# A node is a control plane when its name says so, which is how deploy.sh names
# them and how the node itself decides its reserve.
want_memory_for() {
    case "$1" in
        *-control-plane) echo "${KINC_CONTROL_PLANE_MEMORY:-${KINC_NODE_MEMORY:-}}" ;;
        *)               echo "${KINC_WORKER_MEMORY:-${KINC_NODE_MEMORY:-}}" ;;
    esac
}
want_cpus_for() {
    case "$1" in
        *-control-plane) echo "${KINC_CONTROL_PLANE_CPUS:-${KINC_NODE_CPUS:-}}" ;;
        *)               echo "${KINC_WORKER_CPUS:-${KINC_NODE_CPUS:-}}" ;;
    esac
}

# --- enforced on each node -------------------------------------------------
if [ -n "${KINC_NODE_MEMORY:-}${KINC_CONTROL_PLANE_MEMORY:-}${KINC_WORKER_MEMORY:-}" ]; then
    for n in $nodes; do
        asked=$(want_memory_for "$n")
        got=$(systemctl --user show "${n}.service" -p MemoryHigh --value)
        if [ -z "$asked" ]; then
            [ "$got" = "infinity" ] || fail "${n}: MemoryHigh=${got}, but this role was asked for nothing"
            continue
        fi
        want=$(bytes "$asked")
        if [ "$(bytes "$got")" != "$want" ]; then
            fail "${n}: MemoryHigh is $(bytes "$got") bytes, asked for ${asked} (${want})"
        else
            ok "${n}: enforced at MemoryHigh=${asked}"
        fi
    done
else
    # Bounding a cluster does not bound its nodes. If this asserted only what
    # was asked for, a node limit leaking in from anywhere would pass.
    for n in $nodes; do
        got=$(systemctl --user show "${n}.service" -p MemoryHigh --value)
        [ "$got" = "infinity" ] || fail "${n}: MemoryHigh=${got}, but no per-node memory was asked for"
    done
    [ "$status" -eq 0 ] && ok "${CLUSTER}: no per-node memory limit, as asked"
fi

if [ -n "${KINC_NODE_CPUS:-}${KINC_CONTROL_PLANE_CPUS:-}${KINC_WORKER_CPUS:-}" ]; then
    for n in $nodes; do
        asked=$(want_cpus_for "$n")
        got=$(systemctl --user show "${n}.service" -p CPUQuotaPerSecUSec --value)
        if [ -z "$asked" ]; then
            [ "$got" = "infinity" ] || fail "${n}: CPUQuota=${got}, but this role was asked for nothing"
            continue
        fi
        want_us=$(awk -v c="$asked" 'BEGIN { printf "%d", c * 1000000 }')
        got_us=$(awk -v v="$got" 'BEGIN { sub(/s$/, "", v); printf "%d", v * 1000000 }')
        [ "$got_us" = "$want_us" ] && ok "${n}: enforced at CPUQuota=${asked} cores" \
            || fail "${n}: CPUQuota is ${got}, asked for ${asked} cores"
    done
else
    # Same reason as memory: a quota leaking in from anywhere would otherwise
    # pass, because asserting only what was asked for cannot see it.
    for n in $nodes; do
        got=$(systemctl --user show "${n}.service" -p CPUQuotaPerSecUSec --value)
        [ "$got" = "infinity" ] || fail "${n}: CPUQuota=${got}, but no per-node cpu was asked for"
    done
    [ "$status" -eq 0 ] && ok "${CLUSTER}: no per-node cpu limit, as asked"
fi

# --- floors and weights, read from the kernel ------------------------------
# Asserted against the cgroup rather than against systemctl show, because the
# two disagree exactly where it matters. These are what decide the split when
# the host is contended; the limits above only decide the ceiling, and a node
# that holds its ceiling while being reclaimed to nothing still passes every
# check that looks only at MemoryHigh.
if [ -n "${KINC_NODE_MEMORY:-}${KINC_CONTROL_PLANE_MEMORY:-}${KINC_WORKER_MEMORY:-}" ]; then
    for n in $nodes; do
        asked=$(want_memory_for "$n")
        [ -n "$asked" ] || continue
        want=$(bytes "$asked")
        got=$(cgfile "${n}.service" memory.low)
        if [ -z "$got" ]; then
            fail "${n}: no memory.low in the cgroup - the floor was not applied"
        elif [ "$got" != "$want" ]; then
            fail "${n}: memory.low is ${got} bytes, asked for ${asked} (${want})"
        else
            ok "${n}: floor enforced at memory.low=${asked}"
        fi
    done
fi

if [ -n "${KINC_NODE_CPUS:-}${KINC_CONTROL_PLANE_CPUS:-}${KINC_WORKER_CPUS:-}" ]; then
    for n in $nodes; do
        asked=$(want_cpus_for "$n")
        [ -n "$asked" ] || continue
        want=$(awk -v c="$asked" 'BEGIN { w = int(c * 100); if (w < 1) w = 1; if (w > 10000) w = 10000; print w }')
        got=$(cgfile "${n}.service" cpu.weight)
        if [ "$got" != "$want" ]; then
            fail "${n}: cpu.weight is ${got:-absent}, expected ${want} for ${asked} cores"
        else
            ok "${n}: weighted at cpu.weight=${want}"
        fi

        # io is the one that fails silently. The controller is not delegated to a
        # user manager by default, and without it systemd accepts IOWeight and the
        # kernel never sees it - io.weight does not exist to be read. Asserting the
        # file's absence as a failure is the whole point of checking here: nothing
        # else in this suite can tell a delegated io controller from a missing one.
        io=$(cgfile "${n}.service" io.weight)
        if [ -z "$io" ]; then
            fail "${n}: no io.weight in the cgroup - the io controller was not delegated, so IOWeight is ignored (see tools/ci-prepare-host.sh Check 0c)"
        else
            # io.weight reads back as "default <n>", optionally with per-device lines.
            got_io=$(printf '%s\n' "$io" | awk '/^default /{print $2; exit}')
            [ "$got_io" = "$want" ] && ok "${n}: weighted at io.weight=${want}" \
                || fail "${n}: io.weight is ${got_io:-unparsed}, expected ${want}"
        fi
    done
fi

# --- the slice -------------------------------------------------------------
for n in $nodes; do
    s=$(systemctl --user show "${n}.service" -p Slice --value)
    [ "$s" = "$SLICE" ] || fail "${n}: in slice '${s}', expected '${SLICE}'"
done
if [ -n "${KINC_CLUSTER_MEMORY:-}" ]; then
    # A slice systemd never read reports no FragmentPath and no limits, which
    # is what happens when its unit is left where quadlet looks instead of
    # where systemd does.
    frag=$(systemctl --user show "$SLICE" -p FragmentPath --value)
    [ -n "$frag" ] || fail "${SLICE}: no unit file loaded - its limits are not in effect"
    want=$(bytes "$KINC_CLUSTER_MEMORY")
    got=$(bytes "$(systemctl --user show "$SLICE" -p MemoryHigh --value)")
    [ "$got" = "$want" ] || fail "${SLICE}: MemoryHigh is ${got} bytes, asked for ${KINC_CLUSTER_MEMORY}"
    [ "$status" -eq 0 ] && ok "${CLUSTER}: slice enforced at MemoryHigh=${KINC_CLUSTER_MEMORY}"

    # With both set, whether the cluster is below the sum of its nodes is the
    # whole policy: below, each node may burst and the total is still capped.
    # Reported so the shape under test is on the record rather than inferred
    # from the numbers.
    if [ -n "${KINC_NODE_MEMORY:-}" ]; then
        count=$(printf '%s\n' "$nodes" | grep -c .)
        total=$(( $(bytes "$KINC_NODE_MEMORY") * count ))
        if [ "$want" -lt "$total" ]; then
            say "aggregate cap: ${KINC_CLUSTER_MEMORY} across ${count} nodes that may each reach ${KINC_NODE_MEMORY}"
            frag_slice=$(bytes "$(systemctl --user show "$SLICE" -p MemoryMax --value)")
            [ "$frag_slice" -gt 0 ] || fail "${SLICE}: no MemoryMax backstop above the aggregate cap"
        else
            say "cluster cap is at or above ${count} x ${KINC_NODE_MEMORY}, so the node caps bind first"
        fi
    fi
else
    frag=$(systemctl --user show "$SLICE" -p MemoryHigh --value)
    [ "$frag" = "infinity" ] || fail "${SLICE}: MemoryHigh=${frag}, but no cluster memory was asked for"
    [ "$status" -eq 0 ] && ok "${CLUSTER}: no cluster memory limit, as asked"
fi

# The cluster's cpu quota, which deploy.sh accepts and templates into the slice
# and nothing checked. KINC_CLUSTER_CPUS appeared in this gate exactly once -
# in the "nothing was asked for" branch above - so a quota that was written
# wrong, or not written at all, passed.
if [ -n "${KINC_CLUSTER_CPUS:-}" ]; then
    frag=$(systemctl --user show "$SLICE" -p FragmentPath --value)
    [ -n "$frag" ] || fail "${SLICE}: no unit file loaded - its limits are not in effect"
    want_us=$(awk -v c="$KINC_CLUSTER_CPUS" 'BEGIN { printf "%d", c * 1000000 }')
    got=$(systemctl --user show "$SLICE" -p CPUQuotaPerSecUSec --value)
    got_us=$(awk -v v="$got" 'BEGIN { sub(/s$/, "", v); printf "%d", v * 1000000 }')
    [ "$got_us" = "$want_us" ] || fail "${SLICE}: CPUQuota is ${got}, asked for ${KINC_CLUSTER_CPUS} cores"
    [ "$status" -eq 0 ] && ok "${CLUSTER}: slice enforced at CPUQuota=${KINC_CLUSTER_CPUS} cores"

    # cpu is compressible, so a cluster quota below the sum of its nodes' is
    # not the same bargain memory makes: nodes are throttled against each
    # other rather than reclaimed from, and nothing is killed.
    if [ -n "${KINC_NODE_CPUS:-}" ]; then
        count=$(printf '%s\n' "$nodes" | grep -c .)
        total=$(awk -v c="$KINC_NODE_CPUS" -v n="$count" 'BEGIN { printf "%d", c * n * 1000000 }')
        if [ "$want_us" -lt "$total" ]; then
            say "aggregate quota: ${KINC_CLUSTER_CPUS} cores across ${count} nodes that may each reach ${KINC_NODE_CPUS}"
        else
            say "cluster quota is at or above ${count} x ${KINC_NODE_CPUS} cores, so the node quotas bind first"
        fi
    fi
else
    got=$(systemctl --user show "$SLICE" -p CPUQuotaPerSecUSec --value)
    [ "$got" = "infinity" ] || fail "${SLICE}: CPUQuota=${got}, but no cluster cpu was asked for"
    [ "$status" -eq 0 ] && ok "${CLUSTER}: no cluster cpu limit, as asked"
fi

# --- advertised, which is what the scheduler uses --------------------------
# Per node, because a control plane reserves more than a worker: its static
# pods have no memory request, so nothing else accounts for them.
if [ -n "${KINC_NODE_MEMORY:-}${KINC_CONTROL_PLANE_MEMORY:-}${KINC_WORKER_MEMORY:-}" ]; then
    for n in $nodes; do
        asked=$(want_memory_for "$n")
        got=$(bytes "$(kc get node "$n" -o jsonpath='{.status.allocatable.memory}' 2>/dev/null)")
        if [ -z "$asked" ]; then
            cap=$(bytes "$(kc get node "$n" -o jsonpath='{.status.capacity.memory}' 2>/dev/null)")
            [ "$got" = "$cap" ] || fail "${n}: advertises $(( got / 1048576 ))Mi, but this role was asked for no limit"
            continue
        fi
        if podman exec "$n" test -f /etc/kinc/join/join.conf 2>/dev/null; then
            reserve=$(bytes "${KINC_NODE_RESERVED_MEMORY:-1Gi}")
        else
            reserve=$(bytes "${KINC_NODE_RESERVED_MEMORY:-2Gi}")
        fi
        expect=$(( $(bytes "$asked") - reserve ))
        if [ "$got" != "$expect" ]; then
            fail "${n}: advertises $(( got / 1048576 ))Mi allocatable, expected $(( expect / 1048576 ))Mi (${asked} less its own reserve)"
            say "a node that advertises more than it has admits pods into memory that is not there"
        else
            ok "${n}: advertises ${asked} less its own reserve ($(( got / 1048576 ))Mi)"
        fi
    done
else
    # No per-node limit means no reserve, so a node should advertise the whole
    # machine. Bounding the cluster deliberately does not change that: the
    # nodes share an aggregate and none of them is individually smaller.
    for n in $nodes; do
        cap=$(bytes "$(kc get node "$n" -o jsonpath='{.status.capacity.memory}' 2>/dev/null)")
        alloc=$(bytes "$(kc get node "$n" -o jsonpath='{.status.allocatable.memory}' 2>/dev/null)")
        [ "$alloc" = "$cap" ] || fail "${n}: allocatable $(( alloc / 1048576 ))Mi differs from capacity $(( cap / 1048576 ))Mi with no per-node limit set"
    done
    [ "$status" -eq 0 ] && ok "${CLUSTER}: every node advertises the whole machine, as asked"
fi

echo ""
[ "$status" -eq 0 ] && ok "${CLUSTER}: asked, enforced and advertised all agree" \
                    || echo "❌ ${CLUSTER}: they do not agree"
exit "$status"
