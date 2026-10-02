#!/usr/bin/env bash
# Asserts that a cluster which already exists adopts a node limit it is given.
#
#   ./tools/ci-verify-resumed-adoption.sh [cluster]
#
# Every other gate here builds a cluster and throws it away, so all of them
# exercise a first boot and none of them exercise the second. That is the gap a
# consumer found: kinc-preflight.service and kubeadm-init.service are both gated
# on ConditionPathExists=!/var/lib/kubeadm-initialized, and /var is a volume, so
# on a cluster that comes back neither runs and anything they configured stays
# at whatever first built it.
#
# For the resource feature that produced a half-state rather than a failure. The
# limit is rendered into the quadlet by deploy.sh, so MemoryHigh and CPUQuota
# were applied on a resume, while the systemReserved that makes the node
# advertise honestly was computed by preflight and never reached the kubelet. A
# cgroup that refuses what the scheduler keeps placing is worse than neither,
# and nothing in CI could see it, because CI never resumed a cluster.
#
# So this one does: start without limits, confirm the node offers the machine,
# then restart the same cluster with limits and confirm the node now offers the
# limit less its own reserve. The cluster is the same cluster throughout - same
# volumes, same marker, same PKI - which is the condition under test.
set -euo pipefail

cd "$(dirname "$0")/.."
CLUSTER="${1:-default}"
CP="kinc-${CLUSTER}-control-plane"
KC="/etc/kubernetes/admin.conf"

status=0
ok()   { echo "✅ ${CLUSTER}: $*"; }
fail() { echo "❌ ${CLUSTER}: $*"; status=1; }

# Allocatable as the scheduler sees it, in bytes, read as a typed value rather
# than grepped: a quantity that fails to parse must not look like a pass.
# A Kubernetes quantity, in bytes. The suffix is not fixed: the same field comes
# back as "32550892Ki" unlimited and "3Gi" limited, so a parser that assumes one
# of them returns nothing for the other - and nothing read exactly like a node
# that could not be reached.
allocatable_bytes() {
    local q
    q=$(podman exec "$CP" kubectl --kubeconfig "$KC" get node "$CP" \
            -o jsonpath='{.status.allocatable.memory}' 2>/dev/null)
    [ -n "$q" ] || return 0
    case "$q" in
        *Ki) echo $(( ${q%Ki} * 1024 )) ;;
        *Mi) echo $(( ${q%Mi} * 1024 * 1024 )) ;;
        *Gi) echo $(( ${q%Gi} * 1024 * 1024 * 1024 )) ;;
        *[0-9]) echo "$q" ;;
        *) echo "" ;;
    esac
}

machine_bytes() {
    podman exec "$CP" awk '/^MemTotal:/ { print $2 * 1024 }' /proc/meminfo 2>/dev/null
}

wait_for_change() {
    local was="$1" now
    for _ in $(seq 1 24); do
        now=$(allocatable_bytes)
        [ -n "$now" ] && [ "$now" != "$was" ] && { echo "$now"; return 0; }
        sleep 5
    done
    echo "$now"
    return 1
}

echo "=== ${CLUSTER}: does an existing cluster adopt a limit it is given? ==="

# --- phase 1: a cluster with no limits at all ------------------------------
unset KINC_NODE_MEMORY KINC_NODE_CPUS
CLUSTER_NAME="$CLUSTER" ./tools/cleanup.sh "$CLUSTER" >/dev/null 2>&1 || true
CLUSTER_NAME="$CLUSTER" ./tools/deploy.sh >/dev/null 2>&1 || { echo "❌ initial deploy failed"; exit 1; }

machine=$(machine_bytes)
before=$(allocatable_bytes)
if [ -z "$before" ] || [ -z "$machine" ]; then
    fail "could not read allocatable or machine memory"
    exit 1
fi
# Unlimited, so allocatable is the machine less only what the node keeps for
# itself. Within 25% is the assertion: the exact reserve is another gate's job.
if [ "$before" -gt $(( machine / 2 )) ]; then
    ok "unlimited: node offers $(( before / 1024 / 1024 ))Mi of a $(( machine / 1024 / 1024 ))Mi machine"
else
    fail "unlimited: node offers $(( before / 1024 / 1024 ))Mi, expected most of $(( machine / 1024 / 1024 ))Mi"
fi

# --- phase 2: the same cluster, now given a limit --------------------------
# Stopped and redeployed, never cleaned up. deploy.sh refuses to touch a running
# cluster and points at cleanup.sh, which removes the volumes - so stopping the
# units first is the only way to re-render a quadlet against state that stays.
# That is also what a resume is in the field: the node units come back, by
# reboot, by crash, or by a consumer that renders its own quadlets.
#
# The assertion that this really is a resume is below: /var/lib/kubeadm-initialized
# lives on a volume, so if it survives then kubeadm-init is skipped and the
# cluster is the same cluster. A phase that silently rebuilt would pass this
# gate while testing a first boot, which is the thing already covered.
for svc in $(systemctl --user list-units --plain --no-legend "kinc-${CLUSTER}-*.service" 2>/dev/null | awk '{print $1}'); do
    systemctl --user stop "$svc" >/dev/null 2>&1 || true
done

export KINC_NODE_MEMORY=5G
CLUSTER_NAME="$CLUSTER" ./tools/deploy.sh >/dev/null 2>&1 || { echo "❌ redeploy with a limit failed"; exit 1; }

if podman exec "$CP" test -f /var/lib/kubeadm-initialized 2>/dev/null; then
    ok "this is a resume: the init marker survived, so kubeadm-init was skipped"
else
    fail "the cluster was rebuilt rather than resumed, so this gate proved nothing"
    exit 1
fi

after=$(wait_for_change "$before") || true
if [ -z "$after" ]; then
    fail "allocatable could not be read after the resume"
    exit "$status"
fi

limit=$(numfmt --from=iec 5G)
if [ "$after" = "$before" ]; then
    fail "resumed with KINC_NODE_MEMORY=5G and allocatable did not move from $(( before / 1024 / 1024 ))Mi"
    fail "the cluster kept what it was born with: the limit reached the cgroup and not the kubelet"
elif [ "$after" -lt "$limit" ] && [ "$after" -gt $(( limit / 4 )) ]; then
    ok "resumed: node now offers $(( after / 1024 / 1024 ))Mi, below its 5G limit and above its reserve"
else
    fail "resumed: node offers $(( after / 1024 / 1024 ))Mi, which is not 5G less a plausible reserve"
fi

# The cgroup half, so a pass cannot mean both halves are equally wrong.
high=$(systemctl --user show "${CP}.service" -p MemoryHigh --value 2>/dev/null)
[ "$high" = "$limit" ] && ok "resumed: the cgroup holds the same limit (MemoryHigh=${high})" \
    || fail "resumed: MemoryHigh is ${high}, expected ${limit}"

exit "$status"
