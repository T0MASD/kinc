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
# How big each node is, by the same names deploy.sh uses. Unset means the node
# takes the machine, which is right when it has the machine to itself and wrong
# the moment anything else shares it:
#   KINC_NODE_MEMORY=8G   KINC_NODE_CPUS=11      every node
#   KINC_CONTROL_PLANE_MEMORY / _CPUS            control planes instead
#   KINC_WORKER_MEMORY / _CPUS                   workers instead
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
#
# Joining a control plane to a cluster that audits: pass the same
# KINC_AUDIT_RESOURCES the cluster was created with. The flags come from the
# cluster's own config, but the policy file they name is written per node.
set -euo pipefail

[ $# -ge 4 ] || { sed -n '2,43p' "$0" | sed 's/^# \?//'; exit 1; }
CP_ADDR="$1"; CA_HASH="$2"; SUBNET="$3"; shift 3

IMAGE="${KINC_IMAGE:-localhost/kinc/node:v1.37.1}"
# The cluster's shared control-plane material, needed only to join a control
# plane. Copied here from ~/.local/share/kinc/<cluster>/ca on the machine that
# created the cluster.
CA_DIR="${KINC_CA_DIR:-$HOME/kinc-ca}"
NET="${KINC_NET:-kinc-remote}"
Q="$HOME/.config/containers/systemd"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

[ ${#CA_HASH} -eq 64 ] || { echo "❌ CA hash is not a sha256 digest: '${CA_HASH}'"; exit 1; }

# shellcheck source=tools/lib-node-limits.sh
. "$(dirname "$0")/lib-node-limits.sh"

# Antrea builds its datapath on these. A node starts and goes Ready without them,
# and then every pod scheduled to it fails with
#
#   /var/run/antrea/cni.sock: connect: no such file or directory
#
# which reads as a missing CNI. The agent is what is missing, and its own log says
# why: it tries to modprobe from inside the pod, where a rootless node has no
# CAP_SYS_MODULE. ci-prepare-host.sh does this for the machines it prepares; a
# machine joining from here never runs it.
#
# A module compiled into the kernel never appears in /sys/module, so
# modules.builtin is consulted too.
for m in openvswitch geneve; do
    [ -d "/sys/module/$m" ] && continue
    grep -qw "$m" "/lib/modules/$(uname -r)/modules.builtin" 2>/dev/null && continue
    sudo modprobe "$m" 2>/dev/null || true
    [ -d "/sys/module/$m" ] || {
        echo "❌ kernel module '${m}' is neither loaded nor builtin, and could not be loaded"
        echo "   Antrea needs it on the host; the node will come up Ready and refuse every pod."
        echo "   sudo modprobe ${m}   - and add it to /etc/modules-load.d so a reboot keeps it"
        exit 1; }
done

# The node network's MTU: the host's default-route interface, unless KINC_NODE_MTU
# says otherwise (e.g. when machines reach each other over a tunnel with a
# smaller MTU than the default route). Without it the network inherits pasta's
# 65520 - see runtime/quadlet/kinc-cluster.network.
if [ -z "${KINC_NODE_MTU:-}" ]; then
    _mtu_dev=$(ip -o route show default 2>/dev/null | awk '{for (i=1;i<NF;i++) if ($i=="dev") {print $(i+1); exit}}')
    KINC_NODE_MTU=$(cat "/sys/class/net/${_mtu_dev}/mtu" 2>/dev/null || echo 1500)
fi
if ! [[ "$KINC_NODE_MTU" =~ ^[0-9]+$ ]] || [ "$KINC_NODE_MTU" -lt 1280 ]; then
    echo "❌ KINC_NODE_MTU must be a number of at least 1280, not '${KINC_NODE_MTU}'"
    exit 1
fi
podman network exists "$NET" 2>/dev/null || podman network create --subnet "$SUBNET" --opt mtu="$KINC_NODE_MTU" "$NET" >/dev/null
_have=$(podman network inspect "$NET" --format '{{index .Options "mtu"}}' 2>/dev/null)
[ "$_have" = "$KINC_NODE_MTU" ] || echo "⚠️  network ${NET} has mtu '${_have:-unset}', not ${KINC_NODE_MTU}: it predates this setting; recreate it to apply"
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
    # What podman, systemd and the volumes call this node, as distinct from
    # what Kubernetes calls it.
    #
    # One machine can carry a node of more than one cluster, and the node name
    # is only unique WITHIN a cluster: nexos runs a2-w-1 of apps and a2-w-1 of
    # fleet. Without this they contend for one container name, one quadlet
    # filename and four volume names, and the second join silently adopts the
    # first node's state. kinc_fleet's own VM-side naming is kinc-<cluster>-
    # <node> for exactly this reason.
    #
    # HostName stays ${NAME}: it is what the kubelet registers as, and that
    # must remain the cluster's own name for the node.
    INST="${KINC_INSTANCE_PREFIX:-}${NAME}"
    STATE="$HOME/.local/share/kinc/${INST}"
    WGDIR="$HOME/kinc-wg-${INST}"

    # Sized by the same names deploy.sh uses: KINC_NODE_* for every node, with the
    # per-role variables overriding where the split should be weighted. Unset
    # means unsized, which is what this did for every node before.
    if [ "$ROLE" = "control-plane" ]; then
        _MEM="${KINC_CONTROL_PLANE_MEMORY:-${KINC_NODE_MEMORY:-}}"
        _CPUS="${KINC_CONTROL_PLANE_CPUS:-${KINC_NODE_CPUS:-}}"
    else
        _MEM="${KINC_WORKER_MEMORY:-${KINC_NODE_MEMORY:-}}"
        _CPUS="${KINC_WORKER_CPUS:-${KINC_NODE_CPUS:-}}"
    fi
    # Every node from join-host.sh has a join.conf, both roles, so the
    # node-side default reserve is 1Gi / 200m.
    check_reservation_fits "$_MEM" 1Gi "${NAME}" || exit 1
    check_cpu_reservation_fits "$_CPUS" 200m "${NAME}" || exit 1
    build_role_limits "$_MEM" "$_CPUS"

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

    systemctl --user stop "${INST}.service" 2>/dev/null || true
    rm -rf "$STATE"
    mkdir -p "${STATE}/join" "${STATE}/dropins/kubeadm-init" "${STATE}/dropins/kinc-postinit"
    sed "s|JOIN_SKIP_PHASES_PLACEHOLDER|${SKIP_PHASES}|" \
        runtime/config/dropins/join.conf > "${STATE}/dropins/kubeadm-init/join.conf"
    # The postinit drop-in is role-specific. Both roles skip the cluster-scoped
    # manifests, but a joining control plane still has to drop the taint kubeadm
    # gave it - see runtime/config/dropins/postinit-control-plane.conf. Giving
    # every role the worker drop-in is what left joined control planes tainted.
    if [ "$ROLE" = "control-plane" ]; then
        cp runtime/config/dropins/postinit-control-plane.conf "${STATE}/dropins/kinc-postinit/postinit.conf"
    else
        cp runtime/config/dropins/postinit.conf "${STATE}/dropins/kinc-postinit/postinit.conf"
    fi

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
        podman volume rm -f "${INST}-${v}" >/dev/null 2>&1 || true
        podman volume create "${INST}-${v}" >/dev/null 2>&1 || true
    done

    sed -e "s|kinc-INSTANCE_PLACEHOLDER|${INST}|g" \
        -e "s|kinc-NODE_NAME_PLACEHOLDER|${NAME}|g" \
        -e "s|^Image=.*|Image=${IMAGE}|" \
        -e "s|Volume=kinc-var-data:|Volume=${INST}-var-data:|g" \
        -e "s|Volume=kinc-etc-kubernetes:|Volume=${INST}-etc-kubernetes:|g" \
        -e "s|kinc-var-data-volume.service|${INST}-var-data-volume.service|g" \
        -e "s|kinc-etc-kubernetes-volume.service|${INST}-etc-kubernetes-volume.service|g" \
        -e "s|WG_VOLUME_PLACEHOLDER|${WG_VOLUME}|g" \
        -e "s|CA_VOLUME_PLACEHOLDER|${CA_VOLUME}|g" \
        -e "s|JOIN_DIR_PLACEHOLDER|${STATE}/join|g" \
        -e "s|JOIN_DROPIN_DIR_PLACEHOLDER|${STATE}/dropins/kubeadm-init|g" \
        -e "s|POSTINIT_DROPIN_DIR_PLACEHOLDER|${STATE}/dropins/kinc-postinit|g" \
        -e "s|NETWORK_UNIT_PLACEHOLDER|${NET}|g" \
        -e "s|STORAGE_VOLUME_PLACEHOLDER|${INST}-storage|g" \
        -e "s|NODE_STORE_PLACEHOLDER|${INST}-store|g" \
        -e "s|WORKER_IP_PLACEHOLDER|${POD_IP}|g" \
        -e "s|CLUSTER_SLICE_PLACEHOLDER|${NET}.slice|g" \
        -e "s|NODE_LIMITS_PLACEHOLDER|${_ROLE_LIMITS}|g" \
        runtime/quadlet/kinc-worker.container > "${Q}/${INST}.container"

    # The node's own view of what it was given. Without it the kubelet advertises
    # the whole machine - every core and every byte - while the cgroup above caps
    # it, so the scheduler places against a figure the node cannot honour.
    # deploy.sh has always done this for the nodes it creates; until now a node
    # joined from elsewhere got the ceilings and not the reserves, which is the
    # worse half to have on its own.
    if [ -n "$_ROLE_ENV" ]; then
        sed -i "/^Environment=KUBECONFIG/a ${_ROLE_ENV%\\n}" "${Q}/${INST}.container"
    fi

    # A control plane joining an audited cluster has to be able to audit.
    #
    # The audit flags live in the cluster's ClusterConfiguration, so kubeadm
    # applies them to every control plane it renders - including this one. The
    # policy file they name is written per node by preflight, and only when it
    # is told what to audit. Without this the API server here starts with
    #
    #   loading audit policy file: ... no such file or directory
    #
    # and crashloops. The join then stalls somewhere else entirely: a joining
    # control plane's kubelet bootstraps against its OWN API server, so it waits
    # on a TLS bootstrap that cannot complete, and nothing in that message
    # mentions audit.
    if [ "$ROLE" = "control-plane" ] && [ -n "${KINC_AUDIT_RESOURCES:-}" ]; then
        sed -i "/^Environment=KUBECONFIG/a Environment=KINC_AUDIT_RESOURCES=${KINC_AUDIT_RESOURCES}" \
            "${Q}/${INST}.container"
    fi

    # The cluster's config volume belongs to the machine that built the cluster.
    # Here it would be an empty volume mounted read-only, and preflight fails
    # copying the baked-in config into it. Without the mount preflight uses the
    # image's own writable /etc/kinc/config, which is all a joining node needs:
    # it reads join.conf, not the cluster's kubeadm.conf.
    sed -i "\|/etc/kinc/config|d;s/ *${INST}-config-volume.service//g" "${Q}/${INST}.container"

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
