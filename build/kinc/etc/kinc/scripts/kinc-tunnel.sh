#!/usr/bin/env bash
# Bring up this node's tunnel, on every start.
#
# wg0 lives in the container's network namespace, so restarting a node destroys
# it. Preflight used to create it, but preflight is ConditionPathExists on the
# init marker and is therefore skipped once a node has joined - so a restarted
# node came back with no tunnel, no identity and no way to reach the cluster.
# It presents as a node that is simply never Ready again: the container is up,
# the kubelet is active, and the only clue is "Unable to register mirror pod
# because node is not registered yet".
#
# Idempotent, and a no-op where there is no tunnel material, which is every
# single-machine cluster and every routed-transport node.
set -uo pipefail
log() { echo "$(date -Iseconds) [kinc-tunnel] $*"; }

[[ -s /etc/kinc/wg/private && -s /etc/kinc/wg/address ]] || { log "no tunnel material, nothing to do"; exit 0; }
WG_ADDR="$(tr -d '[:space:]' < /etc/kinc/wg/address)"

ip link show wg0 >/dev/null 2>&1 || ip link add wg0 type wireguard
wg set wg0 private-key /etc/kinc/wg/private listen-port "${KINC_WG_PORT:-51820}"
ip addr show dev wg0 | grep -q "${WG_ADDR}/" || ip addr add "${WG_ADDR}/24" dev wg0
ip link set wg0 up

# peers: <public-key> <allowed-ips> [endpoint]
#
# A full mesh: WireGuard does not relay, so hub-and-spoke through the control
# plane would leave worker-to-worker pod traffic with nowhere to go. An endpoint
# is absent when this side cannot dial that peer; the peer dials in instead and
# keepalive holds the path open.
while read -r peer_pub peer_allowed peer_endpoint; do
    case "$peer_pub" in ""|\#*) continue ;; esac
    if [[ -n "${peer_endpoint:-}" ]]; then
        wg set wg0 peer "$peer_pub" allowed-ips "$peer_allowed" \
            endpoint "$peer_endpoint" persistent-keepalive 25
    else
        wg set wg0 peer "$peer_pub" allowed-ips "$peer_allowed" \
            persistent-keepalive 25
    fi
    # allowed-ips filters what may come OUT of the tunnel; it is not a route
    # into it. Without these, anything outside the address's own prefix leaves
    # by the container's default route instead - a tunnel that handshakes and
    # carries nothing.
    for cidr in ${peer_allowed//,/ }; do
        ip route replace "$cidr" dev wg0 2>/dev/null || true
    done
done < /etc/kinc/wg/peers

log "wg0 up at ${WG_ADDR} with $(wg show wg0 peers | grep -c .) peer(s)"
