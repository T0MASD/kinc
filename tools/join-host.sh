#!/usr/bin/env bash
# Join one machine's worker nodes to a control plane running on another machine.
#
# deploy.sh builds a cluster on the machine it runs on: it creates the control
# plane and every worker locally, and has no notion of a node it does not own.
# This is the other half - run on a second machine, it renders and starts the
# worker nodes that join a control plane elsewhere.
#
# Usage:
#   join-host.sh <cp-endpoint> <ca-hash> <podman-subnet> <node-spec>...
#   node-spec: <name>:<tunnel-address>:<podman-address>
#
# Example, three workers on this machine joining a control plane at .61:
#   join-host.sh 192.168.122.61 <hash> 10.89.50.0/24 \
#       w1:10.99.0.2:10.89.50.11 w2:10.99.0.3:10.89.50.12
#
# Each node's WireGuard material is expected at ~/kinc-wg-<name>/, as written by
# tools/kinc-tunnel-mesh.py. The CA hash comes from the control plane's
# pre-minted CA, so a worker needs nothing from that machine's filesystem and
# can start before the control plane is up.
set -euo pipefail

[ $# -ge 4 ] || { sed -n '3,22p' "$0" | sed 's/^# \?//'; exit 1; }
CP_ADDR="$1"; CA_HASH="$2"; SUBNET="$3"; shift 3

IMAGE="${KINC_IMAGE:-localhost/kinc/node:v1.37.0}"
NET="${KINC_NET:-kinc-remote}"
Q="$HOME/.config/containers/systemd"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

[ ${#CA_HASH} -eq 64 ] || { echo "❌ CA hash is not a sha256 digest: '${CA_HASH}'"; exit 1; }

podman network exists "$NET" 2>/dev/null || podman network create --subnet "$SUBNET" "$NET" >/dev/null
mkdir -p "$Q"
cd "$REPO"

for spec in "$@"; do
    NAME="${spec%%:*}"; rest="${spec#*:}"
    WG_ADDR="${rest%%:*}"; POD_IP="${rest#*:}"
    STATE="$HOME/.local/share/kinc/${NAME}"
    WGDIR="$HOME/kinc-wg-${NAME}"

    [ -s "${WGDIR}/private" ] || { echo "❌ no tunnel material at ${WGDIR}"; exit 1; }

    systemctl --user stop "${NAME}.service" 2>/dev/null || true
    rm -rf "$STATE"
    mkdir -p "${STATE}/join" "${STATE}/dropins/kubeadm-init" "${STATE}/dropins/kinc-postinit"
    cp runtime/config/dropins/join.conf     "${STATE}/dropins/kubeadm-init/join.conf"
    cp runtime/config/dropins/postinit.conf "${STATE}/dropins/kinc-postinit/postinit.conf"

    sed -e "s|CONTROL_PLANE_ENDPOINT_PLACEHOLDER|${CP_ADDR}:6443|g" \
        -e "s|CA_HASH_PLACEHOLDER|${CA_HASH}|g" \
        -e "s|CONTAINER_IP_PLACEHOLDER|${WG_ADDR}|g" \
        runtime/config/join.conf > "${STATE}/join/join.conf"

    # Replace this node's volumes rather than reusing them. A node that joined
    # before left /var/lib/kubeadm-initialized behind, and preflight is
    # ConditionPathExists=!that - so reusing the volume skips preflight, skips
    # the join with it, and the node simply never appears. The unit is active,
    # nothing restarts and nothing is logged as an error, which makes it look
    # like a slow join rather than a node that will never arrive.
    #
    # This is the same thing rm -rf on the host-side state above is doing: the
    # node is being created, so it starts from nothing.
    for v in var-data etc-kubernetes store storage; do
        podman volume rm -f "${NAME}-${v}" >/dev/null 2>&1 || true
        podman volume create "${NAME}-${v}" >/dev/null 2>&1 || true
    done

    sed -e "s|kinc-NODE_NAME_PLACEHOLDER|${NAME}|g" \
        -e "s|^Image=.*|Image=${IMAGE}|" \
        -e "s|Volume=kinc-var-data:|Volume=${NAME}-var-data:|g" \
        -e "s|Volume=kinc-etc-kubernetes:|Volume=${NAME}-etc-kubernetes:|g" \
        -e "s|kinc-var-data-volume.service|${NAME}-var-data-volume.service|g" \
        -e "s|kinc-etc-kubernetes-volume.service|${NAME}-etc-kubernetes-volume.service|g" \
        -e "s|WG_VOLUME_PLACEHOLDER|Volume=${WGDIR}:/etc/kinc/wg:ro,Z|g" \
        -e "s|JOIN_DIR_PLACEHOLDER|${STATE}/join|g" \
        -e "s|JOIN_DROPIN_DIR_PLACEHOLDER|${STATE}/dropins/kubeadm-init|g" \
        -e "s|POSTINIT_DROPIN_DIR_PLACEHOLDER|${STATE}/dropins/kinc-postinit|g" \
        -e "s|NETWORK_UNIT_PLACEHOLDER|${NET}|g" \
        -e "s|STORAGE_VOLUME_PLACEHOLDER|${NAME}-storage|g" \
        -e "s|NODE_STORE_PLACEHOLDER|${NAME}-store|g" \
        -e "s|WORKER_IP_PLACEHOLDER|${POD_IP}|g" \
        -e "s|CLUSTER_SLICE_PLACEHOLDER|${NET}.slice|g" \
        -e "s|NODE_LIMITS_PLACEHOLDER||g" \
        runtime/quadlet/kinc-worker.container > "${Q}/${NAME}.container"

    # The cluster's config volume belongs to the machine that built the cluster.
    # Here it would be an empty volume mounted read-only, and preflight fails
    # copying the baked-in config into it. Without the mount preflight uses the
    # image's own writable /etc/kinc/config, which is all a joining node needs:
    # it reads join.conf, not the cluster's kubeadm.conf.
    sed -i "\|/etc/kinc/config|d;s/ *${NAME}-config-volume.service//g" "${Q}/${NAME}.container"

    echo "  ${NAME}: tunnel ${WG_ADDR}, podman ${POD_IP}"
done

systemctl --user daemon-reload
for spec in "$@"; do
    NAME="${spec%%:*}"
    systemctl --user start "${NAME}.service"
done
echo "✅ started $# node(s); each joins once preflight has brought its tunnel up"
