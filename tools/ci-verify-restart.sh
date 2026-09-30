#!/usr/bin/env bash
#
# Restart every node and assert the cluster comes back as itself.
#
# Usage: ci-verify-restart.sh [cluster]
#
# This is the gate that was missing. A container restart used to destroy a
# cluster permanently - /etc/kubernetes went with the container, taking the PKI
# and the static pod manifests, while the init units declined to rebuild
# because their markers live on /var and /var survived. crio, kubelet and the
# quadlet unit all stayed active throughout, so nothing in the pipeline noticed.
#
# CI never noticed either, because CI only ever initialises a fresh cluster.
# That is also why a once-only unit could write a file nothing would ever write
# again and stay green for releases: the second boot is the one nobody tested.
#
# Restarts are not exotic here. Restart=always is in the quadlet, so any crash
# of the container's PID 1 does this without anyone asking.
set -euo pipefail

CLUSTER="${1:-default}"
KUBECONFIG_FILE=$(mktemp)
trap 'rm -f "$KUBECONFIG_FILE"' EXIT

CP="kinc-${CLUSTER}-control-plane"
echo "=== ${CLUSTER}: restart and come back ==="

nodes=$(podman ps --format '{{.Names}}' | grep "^kinc-${CLUSTER}-" | sort)
[ -n "$nodes" ] || { echo "❌ no nodes running for cluster '${CLUSTER}'"; exit 1; }

# What each node is, before. The address is part of its identity: it is in the
# API server's serving certificate and in every kubeconfig, so a node that
# comes back on a different one is a different node.
declare -A before
for n in $nodes; do
    before[$n]=$(podman inspect "$n" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
    echo "   ${n} at ${before[$n]}"
done

port=$(podman inspect "$CP" --format '{{range $p, $c := .NetworkSettings.Ports}}{{range $c}}{{.HostPort}}{{end}}{{end}}' | head -1)
port="${port:-6443}"
kc() {
    podman exec "$CP" cat /etc/kubernetes/admin.conf 2>/dev/null \
        | sed "s|server: https://.*:6443|server: https://127.0.0.1:${port}|" > "$KUBECONFIG_FILE"
    KUBECONFIG="$KUBECONFIG_FILE" kubectl "$@"
}

# Everything at once, which is the shape a host reboot takes. Restarting only
# the control plane is the easier case and passes whenever this does.
echo "   restarting: $(echo $nodes | tr '\n' ' ')"
# shellcheck disable=SC2086
systemctl --user restart $(for n in $nodes; do printf '%s.service ' "$n"; done)

# The API answering is the first thing that can be true, and it cannot be true
# unless the PKI and the static pod manifests both survived.
deadline=$(( $(date +%s) + 300 ))
until kc get --raw=/healthz >/dev/null 2>&1; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "❌ ${CLUSTER}: the API server did not come back within 300s"
        podman exec "$CP" sh -c 'echo "   pki:       $(ls /etc/kubernetes/pki/*.crt 2>/dev/null | wc -l) certs"
                                 echo "   manifests: $(ls /etc/kubernetes/manifests/ 2>/dev/null | tr "\n" " ")"' || true
        exit 1
    fi
    sleep 5
done
echo "✅ ${CLUSTER}: API server answering after restart"

for n in $nodes; do
    now=$(podman inspect "$n" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
    if [ "$now" != "${before[$n]}" ]; then
        echo "❌ ${n} came back on ${now}, was ${before[$n]} - its certificates name the old address"
        exit 1
    fi
done
echo "✅ ${CLUSTER}: every node kept its address"

if ! kc wait --for=condition=Ready nodes --all --timeout=300s >/dev/null 2>&1; then
    echo "❌ ${CLUSTER}: not every node returned Ready"
    kc get nodes || true
    exit 1
fi
echo "✅ ${CLUSTER}: every node Ready again ($(kc get nodes --no-headers | wc -l) nodes)"

# A cluster whose control plane is up but whose workloads never came back is
# not one that survived, so this asks about the pods rather than the nodes.
deadline=$(( $(date +%s) + 300 ))
until [ "$(kc get pods -n kube-system --no-headers 2>/dev/null | grep -cv 'Running\|Completed')" = "0" ]; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "❌ ${CLUSTER}: kube-system did not settle after restart"
        kc get pods -n kube-system -o wide || true
        exit 1
    fi
    sleep 5
done
echo "✅ ${CLUSTER}: kube-system running again"
echo ""
echo "✅ ${CLUSTER}: survived a restart of every node"
