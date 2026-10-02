#!/usr/bin/env bash
# Join this machine's nodes - workers or control planes - to a cluster whose
# first control plane runs elsewhere.
#
# deploy.sh builds a cluster on the machine it runs on: it creates the first
# control plane and every worker locally, and has no notion of a node it does
# not own. This is the other half.
#
# Usage:
#   join-host.sh <cp-endpoint> <ca-hash> <podman-subnet> <node-spec>...
#   node-spec: <name>:<node-address>:<podman-address>[:<role>]
#   role: worker (default) or control-plane
#
# Example, a control plane and two workers joining the cluster at .61:
#   join-host.sh api.kinc <hash> 10.89.50.0/24 \
#       cp2:10.99.0.4:10.89.50.10:control-plane \
#       w1:10.99.0.2:10.89.50.11 w2:10.99.0.3:10.89.50.12
#
# A control plane additionally needs the cluster's shared material - the three
# CAs and the service account keypair deploy.sh minted - in ~/kinc-ca (or
# $KINC_CA_DIR). Copy that directory from the machine that created the cluster.
# Holding it is what makes a control-plane join need no certificate key: the
# --upload-certs path exists to move this material, and its Secret expires two
# hours after the cluster started, so a cluster grown later could not use it.
#
# A node's address is its identity. With tunnel material at ~/kinc-wg-<name>/
# that is the tunnel address; without it, pass the podman address for both
# fields and the node is reached over whatever routes the host provides.
#
# The CA hash comes from the cluster's pre-minted CA, so a joining node needs
# nothing from the first control plane's filesystem and can start before it is
# up.
set -euo pipefail

[ $# -ge 4 ] || { sed -n '2,31p' "$0" | sed 's/^# \?//'; exit 1; }
CP_ADDR="$1"; CA_HASH="$2"; SUBNET="$3"; shift 3

IMAGE="${KINC_IMAGE:-localhost/kinc/node:v1.37.0}"
# The cluster's shared control-plane material, needed only to join a control
# plane. Copied here from ~/.local/share/kinc/<cluster>/ca on the machine that
# created the cluster.
CA_DIR="${KINC_CA_DIR:-$HOME/kinc-ca}"
NET="${KINC_NET:-kinc-remote}"
Q="$HOME/.config/containers/systemd"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

[ ${#CA_HASH} -eq 64 ] || { echo "❌ CA hash is not a sha256 digest: '${CA_HASH}'"; exit 1; }

podman network exists "$NET" 2>/dev/null || podman network create --subnet "$SUBNET" "$NET" >/dev/null
mkdir -p "$Q"
cd "$REPO"

for spec in "$@"; do
    IFS=: read -r NAME NODE_ADDR POD_IP ROLE <<<"$spec"
    ROLE="${ROLE:-worker}"
    case "$ROLE" in
        worker|control-plane) ;;
        *) echo "❌ ${NAME}: role must be worker or control-plane, not '${ROLE}'"; exit 1 ;;
    esac
    [ -n "${NODE_ADDR:-}" ] && [ -n "${POD_IP:-}" ] \
        || { echo "❌ ${NAME}: spec is <name>:<node-address>:<podman-address>[:<role>]"; exit 1; }
    STATE="$HOME/.local/share/kinc/${NAME}"
    WGDIR="$HOME/kinc-wg-${NAME}"

    # The tunnel is one way to make a node reachable, not the only one, so its
    # material is mounted when present rather than demanded. Without it the node
    # keeps the podman address it was given and is reached however the host
    # routes that - preflight brings up wg0 only when it finds a key.
    WG_VOLUME=""
    if [ -s "${WGDIR}/private" ]; then
        WG_VOLUME="Volume=${WGDIR}:/etc/kinc/wg:ro,Z"
    fi

    # A control plane mints its own serving certificates from the shared CAs, so
    # it needs them before it starts. A worker holds none of this.
    CA_VOLUME=""
    SKIP_PHASES="preflight"
    if [ "$ROLE" = "control-plane" ]; then
        [ -f "${CA_DIR}/ca.key" ] && [ -f "${CA_DIR}/sa.key" ] || {
            echo "❌ ${NAME}: a control plane needs the cluster's shared material in ${CA_DIR}"
            echo "   copy it from the machine that created the cluster:"
            echo "   ~/.local/share/kinc/<cluster>/ca"
            exit 1; }
        CA_VOLUME="Volume=${CA_DIR}:/etc/kinc/ca:ro,Z"
        SKIP_PHASES="preflight,control-plane-prepare/download-certs"
    fi

    systemctl --user stop "${NAME}.service" 2>/dev/null || true
    rm -rf "$STATE"
    mkdir -p "${STATE}/join" "${STATE}/dropins/kubeadm-init" "${STATE}/dropins/kinc-postinit"
    sed "s|JOIN_SKIP_PHASES_PLACEHOLDER|${SKIP_PHASES}|" \
        runtime/config/dropins/join.conf > "${STATE}/dropins/kubeadm-init/join.conf"
    cp runtime/config/dropins/postinit.conf "${STATE}/dropins/kinc-postinit/postinit.conf"

    sed -e "s|CONTROL_PLANE_ENDPOINT_PLACEHOLDER|${CP_ADDR}:6443|g" \
        -e "s|CA_HASH_PLACEHOLDER|${CA_HASH}|g" \
        -e "s|CONTAINER_IP_PLACEHOLDER|${NODE_ADDR}|g" \
        runtime/config/join.conf > "${STATE}/join/join.conf"

    # What makes this a control-plane join rather than a worker one. Appended
    # rather than templated: the rest of the config is the same document a
    # worker uses, and a second template would be one more thing to keep in
    # step with it.
    if [ "$ROLE" = "control-plane" ]; then
        cat >> "${STATE}/join/join.conf" <<YAML
controlPlane:
  localAPIEndpoint:
    advertiseAddress: ${NODE_ADDR}
    bindPort: 6443
YAML
    fi

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
        -e "s|WG_VOLUME_PLACEHOLDER|${WG_VOLUME}|g" \
        -e "s|CA_VOLUME_PLACEHOLDER|${CA_VOLUME}|g" \
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

    echo "  ${NAME}: ${ROLE}, address ${NODE_ADDR}, podman ${POD_IP}"
done

systemctl --user daemon-reload
for spec in "$@"; do
    NAME="${spec%%:*}"
    systemctl --user start "${NAME}.service"
done
echo "✅ started $# node(s); each joins once preflight has finished"

# NodeRestriction refuses every kubernetes.io label a kubelet sets for itself,
# so a role is applied with the cluster's credentials after the node registers.
# deploy.sh does that for the workers it creates because it holds admin.conf;
# this machine deliberately holds nothing of the cluster's, so the step belongs
# wherever those credentials are.
#
# Said out loud because the absence is quiet: an unlabelled node is Ready and
# schedulable, and only a nodeSelector asking for a role - which is what the
# cross-node gate and most placement rules use - ever notices.
echo
echo "   Nodes carry no role until one is applied from the control plane:"
for spec in "$@"; do
    IFS=: read -r n _ _ r <<<"$spec"
    case "${r:-worker}" in
        control-plane) ;;
        *) echo "     kubectl label node ${n} node-role.kubernetes.io/worker= --overwrite" ;;
    esac
done
