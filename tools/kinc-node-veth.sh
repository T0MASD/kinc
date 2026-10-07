#!/usr/bin/env bash
# Make this machine's node containers reachable from other machines without a
# tunnel, by routing their subnet through a veth into the rootless namespace.
#
# The problem it solves: rootless podman puts its network in a user namespace of
# its own. Every machine's podman allocates from the same range, so two machines
# hand their containers identical addresses and neither can reach the other's -
# and rootlessport rewrites source addresses, so even a published port arrives
# looking like it came from the host. Bridging the hypervisors does not help;
# the namespace is the boundary, not the LAN.
#
# A routed veth carries packets unmodified, so a node keeps its own address and
# can be reached at it. Where the WireGuard transport gives a node an identity
# it owns, this one makes the address it already has routable.
#
# Routed, not bridged. A veth enslaved to the podman bridge makes replies leave
# the interface they arrived on and they are dropped; a point-to-point link is
# symmetric, so conntrack stays consistent.
#
# Run as root, and as a service rather than once: the namespace is created with
# the first container and destroyed with the last, taking the veth and the
# routes with it. A node replaced by hand then has working egress and no
# ingress, which nothing logs.
#
#   POD_SUBNET=10.89.21.0/24 HOST_ADDR=10.99.21.1/30 NS_ADDR=10.99.21.2/30 \
#       kinc-node-veth.sh
#
# Each machine also needs a route to every other machine's node subnet, and
# ip_forward on. tools/install-node-veth.sh does both and installs this as a
# unit.
set -uo pipefail
TENANT_UID="${TENANT_UID:-$(id -u "${SUDO_USER:-$USER}")}"
POD_SUBNET="${POD_SUBNET:?the node subnet on this machine, e.g. 10.89.21.0/24}"
HOST_ADDR="${HOST_ADDR:?transit address, host side, e.g. 10.99.21.1/30}"
NS_ADDR="${NS_ADDR:?transit address, namespace side, e.g. 10.99.21.2/30}"
VETH_HOST="${VETH_HOST:-kincv0}"
VETH_NS="${VETH_NS:-kincv1}"
INTERVAL="${INTERVAL:-10}"
ONESHOT="${ONESHOT:-0}"

# Both the node subnets and the transit subnets have to escape netavark's
# masquerade. Matching only the first leaves inter-node traffic rewritten to the
# transit address, which the far side has no route back to - the reply is lost
# and nothing on the far interface shows the packet arriving.
NODE_SUPERNETS="${NODE_SUPERNETS:-10.89.0.0/16 10.99.0.0/16}"

NETNS="/run/user/${TENANT_UID}/containers/networks/rootless-netns/rootless-netns"
HOST_IP="${HOST_ADDR%/*}"; NS_IP="${NS_ADDR%/*}"
log() { echo "$(date -Iseconds) [kinc-node-veth] $*"; }

# The namespace cannot be named from the host, but any process already inside it
# can be borrowed as a handle - conmon is the one that is always there.
find_handle() {
    local p
    for p in $(pgrep -x conmon 2>/dev/null); do
        grep -q "rootless-netns" "/proc/$p/mountinfo" 2>/dev/null && { echo "$p"; return 0; }
    done
    return 1
}
NSRUN() { nsenter -t "$HANDLE" -m -- nsenter --net="$NETNS" "$@"; }
external_if() { ip route get 8.8.8.8 2>/dev/null | awk '/dev/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'; }

apply_nat() {
    # Masquerade the TRANSIT subnet, not the node subnet: netavark already
    # rewrites to whatever leaves the namespace, which is now this veth, so
    # traffic reaches the host as ${NS_IP}. A rule matching the node subnet
    # matches nothing and costs every container its egress.
    #
    # Only for traffic leaving the external interface. Inter-node traffic must
    # not be translated or a node's identity is lost on the way.
    nft -f - <<NFT
table ip kinc_veth
delete table ip kinc_veth
table ip kinc_veth {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr ${NS_ADDR} oifname "$1" masquerade
    }
}
NFT
}

assert() {
    [ -e "$NETNS" ] || { log "no rootless netns yet (start a node first)"; return 1; }
    HANDLE=$(find_handle) || { log "no conmon handle into the namespace"; return 1; }
    local extif; extif=$(external_if); [ -n "$extif" ] || return 1

    if ! NSRUN ip link show "$VETH_NS" >/dev/null 2>&1; then
        log "plumbing ${VETH_HOST} <-> ${VETH_NS}"
        ip link del "$VETH_HOST" 2>/dev/null || true
        # Created inside the namespace and one end pushed out, because pid 1 can
        # always be named from within it.
        NSRUN ip link add "$VETH_NS" type veth peer name "$VETH_HOST" || return 1
        NSRUN ip link set "$VETH_HOST" netns 1 || return 1
        NSRUN ip addr add "$NS_ADDR" dev "$VETH_NS" 2>/dev/null || true
        NSRUN ip link set "$VETH_NS" up
    fi
    ip link show "$VETH_HOST" >/dev/null 2>&1 || return 1
    ip addr show dev "$VETH_HOST" | grep -q "$HOST_IP" || ip addr add "$HOST_ADDR" dev "$VETH_HOST" 2>/dev/null || true
    ip link set "$VETH_HOST" up
    ip route replace "$POD_SUBNET" via "$NS_IP" dev "$VETH_HOST"
    NSRUN ip route replace default via "$HOST_IP" dev "$VETH_NS"
    apply_nat "$extif"

    # Re-asserted every pass: netavark rewrites its ruleset whenever a container
    # changes, and the exemption goes at the top of its own chain so a verdict
    # reached elsewhere does not pre-empt it.
    local c sn
    for c in $(NSRUN nft -a list table inet netavark 2>/dev/null \
               | awk '/chain nv_/{n=$2} /masquerade/{if(n)print n}' | sort -u); do
        for sn in $NODE_SUPERNETS; do
            NSRUN nft list chain inet netavark "$c" 2>/dev/null \
              | grep -q "daddr ${sn} return" && continue
            NSRUN nft insert rule inet netavark "$c" ip daddr "$sn" return 2>/dev/null \
              && log "exempted ${sn} from masquerade in $c"
        done
    done
    return 0
}

sysctl -qw net.ipv4.ip_forward=1
if [ "$ONESHOT" = "1" ]; then
    assert && log "ok: ${POD_SUBNET} routed via ${VETH_HOST} -> ${NS_IP}" || { log "FAILED"; exit 1; }
    exit 0
fi
log "starting: subnet=${POD_SUBNET} transit=${HOST_ADDR} exempt=${NODE_SUPERNETS}"
while true; do assert; sleep "$INTERVAL"; done
