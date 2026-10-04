#!/usr/bin/env bash
# Asserts that a node restarted onto a different image comes back configured by
# the image it is now running.
#
#   ./tools/ci-verify-image-change-restart.sh [cluster]
#
# ci-verify-restart.sh restarts a node on the same image, which proves identity:
# the cluster is the same cluster, the addresses hold, the PKI survived. It
# cannot prove configuration, because there is no configuration difference for
# it to see.
#
# For a consumer whose clusters are resumed rather than rebuilt, a restart
# normally crosses an image change - the VM is rebuilt from a new bootc image
# while the state disk survives. A node then comes back with new binaries and
# whatever configuration the cluster was born with, because every provisioning
# step is gated on /var/lib/kubeadm-initialized and /var is a volume. Nothing
# reports the mismatch.
#
# That one gap hid three separate bugs: the Faro kubeconfig, the ownership of
# its events directory, and the node's resource reservations. None of them is
# visible to a same-image restart, and all three are visible here.
#
# So: boot on the image the cluster was built with, derive a second image that
# differs only in a value a provisioning step renders, restart a node onto it,
# and assert the new value is in effect and the cluster is still the same
# cluster. The second half matters as much as the first - a phase that quietly
# rebuilt would satisfy the first and prove nothing.
set -euo pipefail

cd "$(dirname "$0")/.."
CLUSTER="${1:-default}"
# The image to restart onto. Given, this is an upgrade: the caller deployed the
# cluster from some other image and this moves it onto the one named. Omitted,
# a sibling is derived from whatever the cluster is running, which tests the
# mechanism and nothing about history.
TARGET_IMAGE="${2:-}"
CP="kinc-${CLUSTER}-control-plane"
KC="/etc/kubernetes/admin.conf"
QUADLET=~/.config/containers/systemd/${CP}.container

status=0
ok()   { echo "✅ ${CLUSTER}: $*"; }
fail() { echo "❌ ${CLUSTER}: $*"; status=1; }

kq() { podman exec "$CP" kubectl --kubeconfig "$KC" "$@" 2>/dev/null; }

# A Kubernetes quantity in bytes. The suffix varies with the value, so a parser
# that assumes one spelling returns nothing for the other, and nothing reads
# exactly like a node that could not be reached.
allocatable_bytes() {
    local q; q=$(kq get node "$CP" -o jsonpath='{.status.allocatable.memory}')
    [ -n "$q" ] || return 0
    case "$q" in
        *Ki) echo $(( ${q%Ki} * 1024 )) ;;
        *Mi) echo $(( ${q%Mi} * 1024 * 1024 )) ;;
        *Gi) echo $(( ${q%Gi} * 1024 * 1024 * 1024 )) ;;
        *[0-9]) echo "$q" ;;
        *) echo "" ;;
    esac
}

echo "=== ${CLUSTER}: does a node restarted onto a new image adopt its configuration? ==="

podman ps --format '{{.Names}}' | grep -qx "$CP" || { echo "❌ ${CP} is not running"; exit 1; }
[ -f "$QUADLET" ] || { echo "❌ no quadlet at ${QUADLET}"; exit 1; }

IMAGE_A=$(podman inspect "$CP" --format '{{.ImageName}}')
born=$(kq get node "$CP" -o jsonpath='{.metadata.creationTimestamp}')
before=$(allocatable_bytes)
[ -n "$before" ] && [ -n "$born" ] || { echo "❌ could not read the node's starting state"; exit 1; }
echo "   on ${IMAGE_A}, allocatable $(( before / 1024 / 1024 ))Mi, node created ${born}"

# --- the image to restart onto ---------------------------------------------
DERIVED=0
if [ -n "$TARGET_IMAGE" ]; then
    # An upgrade. The cluster's state was created by whatever built it, which is
    # the point: a derived sibling shares this tree, so every directory it owns
    # and every file it staged was written by current provisioning. The bugs
    # worth catching here are the opposite - state an older release left behind.
    # A root-owned events directory only exists on a cluster built before the
    # install -d line did; a missing staged kubeconfig only matters where init
    # predates the unit that stages it.
    podman image exists "$TARGET_IMAGE" || podman pull -q "$TARGET_IMAGE" >/dev/null 2>&1
    podman image exists "$TARGET_IMAGE" || { echo "❌ ${TARGET_IMAGE} is not available"; exit 1; }
    IMAGE_B="$TARGET_IMAGE"
    ok "upgrading from ${IMAGE_A##*/} to ${IMAGE_B##*/}"
else
    # One layer over A, changing the default a provisioning step reads. Not a
    # rebuild: everything else about the image is the same, so what the
    # assertion sees can only come from the change.
    DERIVED=1
    IMAGE_B="localhost/kinc/node:imagechange-test"
    podman build -q -t "$IMAGE_B" -f - . >/dev/null 2>&1 <<EOF
FROM ${IMAGE_A}
RUN sed -i 's/KINC_NODE_RESERVED_MEMORY:-2Gi/KINC_NODE_RESERVED_MEMORY:-3Gi/' \
    /etc/kinc/scripts/kinc-node-resources.sh \
 && grep -q 'KINC_NODE_RESERVED_MEMORY:-3Gi' /etc/kinc/scripts/kinc-node-resources.sh
EOF
    [ "${PIPESTATUS[0]:-0}" -eq 0 ] || true
    podman image exists "$IMAGE_B" || { echo "❌ could not derive the second image"; exit 1; }
    ok "derived ${IMAGE_B}, which reserves 3Gi where ${IMAGE_A##*/} reserves 2Gi"
fi

# --- restart the node onto it ----------------------------------------------
# The quadlet is repointed and the unit restarted. The volumes are untouched,
# which is what makes this a resume rather than a rebuild.
sed -i "s|^Image=.*|Image=${IMAGE_B}|" "$QUADLET"
systemctl --user daemon-reload
systemctl --user restart "${CP}.service"

for _ in $(seq 1 36); do
    kq get --raw /readyz >/dev/null 2>&1 && break
    sleep 5
done

# --- assert -----------------------------------------------------------------
running=$(podman inspect "$CP" --format '{{.ImageName}}' 2>/dev/null)
[ "$running" = "$IMAGE_B" ] && ok "the node is running ${IMAGE_B}" \
    || fail "the node is running ${running}, expected ${IMAGE_B}"

if podman exec "$CP" test -f /var/lib/kubeadm-initialized 2>/dev/null; then
    ok "the init marker survived, so this was a resume and not a rebuild"
else
    fail "the init marker is gone: the cluster was rebuilt, so this proved nothing"
fi

now_born=$(kq get node "$CP" -o jsonpath='{.metadata.creationTimestamp}')
[ "$now_born" = "$born" ] && ok "the node kept its original creation timestamp (${born})" \
    || fail "the node object was recreated: ${born} became ${now_born:-<absent>}"

after=$(allocatable_bytes)
if [ "$DERIVED" -eq 1 ]; then
    # The derived image reserves more, so allocatable must fall.
    if [ -z "$after" ]; then
        fail "allocatable could not be read after the restart"
    elif [ "$after" = "$before" ]; then
        fail "allocatable is unchanged at $(( before / 1024 / 1024 ))Mi"
        fail "the node came back on a new image carrying the configuration it was born with"
    elif [ "$after" -lt "$before" ]; then
        ok "allocatable moved $(( before / 1024 / 1024 ))Mi → $(( after / 1024 / 1024 ))Mi: the new image's reserve is in effect"
    else
        fail "allocatable rose to $(( after / 1024 / 1024 ))Mi, which the new image's larger reserve cannot explain"
    fi
    # Not -f. The node is still running this image, and `podman rmi -f` on an
    # image in use stops and removes the containers using it - so the gate
    # destroyed the cluster it had just verified, and whatever ran next found
    # no nodes to capture. Plain rmi declines while the container lives, which
    # is the behaviour wanted: tidy up if the cluster is already gone, never
    # take it down to do so.
    podman rmi "$IMAGE_B" >/dev/null 2>&1 || true
    exit "$status"
fi

# --- an upgrade: what provisioning from an older release left behind --------
#
# Each of these was a real bug, and each was invisible both to a fresh build and
# to a restart within one source tree. They are asserted on the cluster, after
# the restart, because that is the only moment the old state and the new image
# exist together.

# The reservation this node resolved. On a cluster whose init predates
# kinc-node-resources.service, nothing wrote this and allocatable stayed at the
# machine's size while the cgroup held the limit.
if podman exec "$CP" test -f /etc/kubernetes/kubelet.conf.d/20-kinc-node-resources.conf 2>/dev/null; then
    ok "the node rendered its reservation after the upgrade"
    cap=$(podman exec "$CP" awk '/^MemTotal:/ { print $2 * 1024 }' /proc/meminfo 2>/dev/null)
    if [ -n "$after" ] && [ -n "$cap" ] && [ "$after" -lt "$cap" ]; then
        ok "and advertises less than the machine ($(( after / 1024 / 1024 ))Mi of $(( cap / 1024 / 1024 ))Mi)"
    else
        fail "advertises $(( ${after:-0} / 1024 / 1024 ))Mi against a machine of $(( ${cap:-0} / 1024 / 1024 ))Mi"
    fi
else
    fail "no reservation was rendered: provisioning from the older release was not redone"
fi

# Faro's events directory and staged kubeconfig, both of which an older
# release created root-owned or not at all.
if podman exec "$CP" test -d /var/lib/kinc/faro-events 2>/dev/null; then
    owner=$(podman exec "$CP" stat -c '%u:%g' /var/lib/kinc/faro-events 2>/dev/null)
    [ "$owner" = "65532:65532" ] \
        && ok "the Faro events directory is owned by 65532 after the upgrade" \
        || fail "the Faro events directory is owned by ${owner}, so Faro cannot write to it"
fi
if podman exec "$CP" test -f /etc/kinc/faro/kubeconfig 2>/dev/null; then
    owner=$(podman exec "$CP" stat -c '%u:%g' /etc/kinc/faro/kubeconfig 2>/dev/null)
    [ "$owner" = "65532:65532" ] \
        && ok "the staged Faro kubeconfig is present and owned by 65532" \
        || fail "the staged Faro kubeconfig is owned by ${owner}"
fi

exit "$status"
