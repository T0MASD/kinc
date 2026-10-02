#!/usr/bin/env bash
# Install the routed veth as a service, and add the routes that make the other
# machines' node subnets reachable from this one.
#
# Usage:
#   install-node-veth.sh <this-machine-subnet> <transit-/30> [<peer-addr>=<subnet>]...
#
# Example, on the machine holding 10.89.21.0/24, with two peers:
#   install-node-veth.sh 10.89.21.0/24 10.99.21.0/30 \
#       10.78.0.22=10.89.22.0/24 10.78.0.71=10.89.43.0/24
#
# The transit /30 is a point-to-point link between the host and the namespace;
# it carries no node traffic and only has to be unique on this machine. Give
# each machine a different one anyway, so a packet's source says where it came
# from.
#
# A service rather than a one-shot because podman's namespace dies with the last
# container: replacing a node otherwise leaves the host routing its subnet to a
# veth that no longer exists, which looks like a node that joined and went
# quiet. See tools/kinc-node-veth.sh.
set -euo pipefail
[ $# -ge 2 ] || { sed -n '2,20p' "$0" | sed 's/^# \?//'; exit 1; }
SUBNET="$1"; TRANSIT="$2"; shift 2

[[ "$SUBNET"  =~ ^[0-9.]+\.0/24$   ]] || { echo "❌ subnet must be a /24 ending in .0: '${SUBNET}'"; exit 1; }
[[ "$TRANSIT" =~ ^([0-9.]+)\.0/30$ ]] || { echo "❌ transit must be a /30 ending in .0: '${TRANSIT}'"; exit 1; }
TP="${BASH_REMATCH[1]}"
HOST_ADDR="${TP}.1/30"; NS_ADDR="${TP}.2/30"

SELF=$(dirname "$(readlink -f "$0")")
sudo install -m 0755 "${SELF}/kinc-node-veth.sh" /usr/local/sbin/kinc-node-veth.sh
sudo tee /etc/systemd/system/kinc-node-veth.service >/dev/null <<UNIT
[Unit]
Description=Routed veth into the rootless podman namespace
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=TENANT_UID=$(id -u)
Environment=POD_SUBNET=${SUBNET}
Environment=HOST_ADDR=${HOST_ADDR}
Environment=NS_ADDR=${NS_ADDR}
Environment=INTERVAL=10
ExecStart=/usr/local/sbin/kinc-node-veth.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable --now kinc-node-veth.service >/dev/null 2>&1 || true

# Reciprocal routes. Not the veth's job: it makes this machine's subnet
# reachable, these say where the others are.
#
# No "dev": the interface carrying the peers is not necessarily the one holding
# the default route, and naming the wrong one fails with "Nexthop has invalid
# gateway" rather than anything about interfaces. The kernel resolves it from
# the gateway address, which is the only thing we actually know.
sudo sysctl -qw net.ipv4.ip_forward=1
PEER_IFS=""
for peer in "$@"; do
    via="${peer%%=*}"; net="${peer##*=}"
    [ "$net" = "$SUBNET" ] && continue
    if ! sudo ip route replace "$net" via "$via"; then
        echo "❌ no route to ${via}; is this machine on the same network as that peer?"
        exit 1
    fi
    dev=$(ip route get "$via" 2>/dev/null | awk '/dev/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    case " $PEER_IFS " in *" $dev "*) ;; *) PEER_IFS="${PEER_IFS} ${dev}" ;; esac
    echo "  route ${net} via ${via} (dev ${dev})"
done

# firewalld filters forwarded traffic too, and a node subnet arriving from
# another machine is forwarded, not delivered locally. --permanent because a
# runtime-only zone change is undone by the next reload, and the symptom then
# is "host unreachable - admin prohibited filter" long after the change.
if command -v firewall-cmd >/dev/null 2>&1 && sudo firewall-cmd --state >/dev/null 2>&1; then
    for i in kincv0 $PEER_IFS; do
        sudo firewall-cmd --permanent --zone=trusted --change-interface="$i" >/dev/null 2>&1 || true
    done
    sudo firewall-cmd --reload >/dev/null 2>&1 || true
    echo "  trusted: $(sudo firewall-cmd --zone=trusted --list-interfaces)"
fi

sleep 12
echo "  $(hostname): $(systemctl is-active kinc-node-veth.service), kincv0=$(ip -4 -o addr show kincv0 2>/dev/null | awk '{print $4}')"
ip route | grep "dev kincv0" | sed 's/^/    /'
