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

nodes=$(podman ps --format '{{.Names}}' | grep "^kinc-${CLUSTER}-" | sort)
[ -n "$nodes" ] || { echo "❌ no nodes running for cluster '${CLUSTER}'"; exit 1; }

KUBECONFIG_FILE=$(mktemp); trap 'rm -f "$KUBECONFIG_FILE"' EXIT
port=$(podman inspect "$CP" --format '{{range $p, $c := .NetworkSettings.Ports}}{{range $c}}{{.HostPort}}{{end}}{{end}}' | head -1)
podman exec "$CP" cat /etc/kubernetes/admin.conf 2>/dev/null \
    | sed "s|server: https://.*:6443|server: https://127.0.0.1:${port:-6443}|" > "$KUBECONFIG_FILE"
kc() { KUBECONFIG="$KUBECONFIG_FILE" kubectl "$@"; }

echo "=== ${CLUSTER}: node resources ==="

# --- nothing asked for: assert nothing was done ---------------------------
if [ -z "${KINC_NODE_MEMORY:-}${KINC_NODE_CPUS:-}${KINC_CLUSTER_MEMORY:-}${KINC_CLUSTER_CPUS:-}" ]; then
    for n in $nodes; do
        for prop in MemoryHigh MemoryMax; do
            v=$(systemctl --user show "${n}.service" -p "$prop" --value)
            [ "$v" = "infinity" ] || fail "${n}: ${prop}=${v}, but no limit was asked for"
        done
        q=$(systemctl --user show "${n}.service" -p CPUQuotaPerSecUSec --value)
        [ "$q" = "infinity" ] || fail "${n}: CPUQuota=${q}, but no limit was asked for"
    done
    [ "$status" -eq 0 ] && ok "${CLUSTER}: unlimited, as asked"
    exit "$status"
fi

# --- enforced on each node -------------------------------------------------
if [ -n "${KINC_NODE_MEMORY:-}" ]; then
    want=$(bytes "$KINC_NODE_MEMORY")
    for n in $nodes; do
        got=$(bytes "$(systemctl --user show "${n}.service" -p MemoryHigh --value)")
        if [ "$got" != "$want" ]; then
            fail "${n}: MemoryHigh is ${got} bytes, asked for ${KINC_NODE_MEMORY} (${want})"
        fi
    done
    [ "$status" -eq 0 ] && ok "${CLUSTER}: every node enforced at MemoryHigh=${KINC_NODE_MEMORY}"
fi

if [ -n "${KINC_NODE_CPUS:-}" ]; then
    want_us=$(awk -v c="$KINC_NODE_CPUS" 'BEGIN { printf "%d", c * 1000000 }')
    for n in $nodes; do
        got=$(systemctl --user show "${n}.service" -p CPUQuotaPerSecUSec --value)
        got_us=$(awk -v v="$got" 'BEGIN { sub(/s$/, "", v); printf "%d", v * 1000000 }')
        [ "$got_us" = "$want_us" ] || fail "${n}: CPUQuota is ${got}, asked for ${KINC_NODE_CPUS} cores"
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
fi

# --- advertised, which is what the scheduler uses --------------------------
# Per node, because a control plane reserves more than a worker: its static
# pods have no memory request, so nothing else accounts for them.
if [ -n "${KINC_NODE_MEMORY:-}" ]; then
    limit=$(bytes "$KINC_NODE_MEMORY")
    for n in $nodes; do
        if podman exec "$n" test -f /etc/kinc/join/join.conf 2>/dev/null; then
            reserve=$(bytes "${KINC_NODE_RESERVED_MEMORY:-1Gi}")
        else
            reserve=$(bytes "${KINC_NODE_RESERVED_MEMORY:-2Gi}")
        fi
        expect=$(( limit - reserve ))
        got=$(bytes "$(kc get node "$n" -o jsonpath='{.status.allocatable.memory}' 2>/dev/null)")
        if [ "$got" != "$expect" ]; then
            fail "${n}: advertises $(( got / 1048576 ))Mi allocatable, expected $(( expect / 1048576 ))Mi (${KINC_NODE_MEMORY} less its own reserve)"
            say "a node that advertises more than it has admits pods into memory that is not there"
        fi
    done
    [ "$status" -eq 0 ] && ok "${CLUSTER}: every node advertises its limit less its own reserve"
fi

echo ""
[ "$status" -eq 0 ] && ok "${CLUSTER}: asked, enforced and advertised all agree" \
                    || echo "❌ ${CLUSTER}: they do not agree"
exit "$status"
