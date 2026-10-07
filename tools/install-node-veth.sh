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
# Environment, both optional:
#   TENANT_UID       whose rootless namespace to plumb into. Defaults to the
#                    invoking user, through SUDO_USER; set it when running as
#                    root for a service user that has no sudo rights.
#   NODE_SUPERNETS   space-separated ranges that must keep their source address
#                    across machines. Defaults to kinc's own 10.89.0.0/16 and
#                    10.99.0.0/16; a fleet addressed differently must say so.
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
[ $# -ge 2 ] || { sed -n '2,28p' "$0" | sed 's/^# \?//'; exit 1; }
SUBNET="$1"; TRANSIT="$2"; shift 2

[[ "$SUBNET"  =~ ^[0-9.]+\.0/24$   ]] || { echo "❌ subnet must be a /24 ending in .0: '${SUBNET}'"; exit 1; }
[[ "$TRANSIT" =~ ^([0-9.]+)\.0/30$ ]] || { echo "❌ transit must be a /30 ending in .0: '${TRANSIT}'"; exit 1; }
TP="${BASH_REMATCH[1]}"
HOST_ADDR="${TP}.1/30"; NS_ADDR="${TP}.2/30"

# Whose namespace this veth goes into. The script sudo's for everything it does,
# so it is meant to be run as the node's user - but a service user often has no
# sudo rights at all, and then the only way to run it is as root, where id -u is
# 0 and the veth is plumbed into root's namespace instead of the node's. The unit
# comes up, the node comes up, and nothing routes.
#
# SUDO_USER covers `sudo install-node-veth.sh`, and TENANT_UID covers running it
# as root outright. Same resolution the service itself uses.
TENANT_UID="${TENANT_UID:-$(id -u "${SUDO_USER:-$USER}")}"

# What must NOT be masqueraded on the way out of the namespace: the ranges that
# carry node-to-node traffic, where a node's own address is its identity. kinc's
# own addressing by default; a fleet on anything else passes its ranges here.
NODE_SUPERNETS="${NODE_SUPERNETS:-10.89.0.0/16 10.99.0.0/16}"

SELF=$(dirname "$(readlink -f "$0")")
sudo install -m 0755 "${SELF}/kinc-node-veth.sh" /usr/local/sbin/kinc-node-veth.sh
sudo tee /etc/systemd/system/kinc-node-veth.service >/dev/null <<UNIT
[Unit]
Description=Routed veth into the rootless podman namespace
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=TENANT_UID=${TENANT_UID}
Environment=POD_SUBNET=${SUBNET}
Environment=HOST_ADDR=${HOST_ADDR}
Environment=NS_ADDR=${NS_ADDR}
Environment=INTERVAL=10
# Quoted, because Environment= splits on whitespace: unquoted, a list of networks
# sets only the first and discards the rest with one warning in the journal. The
# default here is kinc's own addressing; a fleet using any other range has to say
# so, or every packet leaving a node is masqueraded to the transit address and
# the node looks like it has no network at all.
Environment="NODE_SUPERNETS=${NODE_SUPERNETS}"
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
