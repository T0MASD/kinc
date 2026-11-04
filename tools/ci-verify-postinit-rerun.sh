#!/usr/bin/env bash
#
# Run kinc-postinit again on a finished cluster and assert it changes nothing.
#
# Usage: ci-verify-postinit-rerun.sh [cluster]
#
# postinit runs on every control plane that joins, and systemd retries it on
# every failure. On 2026-11-02 a joining control plane failed in it on every
# run - `kubectl apply` of a PersistentVolume an older image had made with
# another hostPath, which is immutable - and retried every 10 s for two days.
# Each run re-applied kubeadm's kube-proxy addon and patched it back: two
# DaemonSet rollouts, kube-proxy restarted on every node, 7,534 times. So a
# second run has to be a no-op for the cluster, including against a PV that
# differs from what this image would create.
#
# Before ci-verify-restart.sh: the run reads /tmp/kubeadm-final.conf, which
# lives on the boot it was rendered in.
set -euo pipefail

CLUSTER="${1:-default}"
CP="kinc-${CLUSTER}-control-plane"
# -i, so a manifest on stdin reaches kubectl.
k() { podman exec -i "$CP" env KUBECONFIG=/etc/kubernetes/admin.conf kubectl "$@"; }
gen() { k -n kube-system get "$1" -o jsonpath='{.metadata.generation}'; }

echo "=== ${CLUSTER}: kinc-postinit run again changes nothing ==="

kp_before=$(gen daemonset/kube-proxy)
dns_before=$(gen deployment/coredns)

# An older image's shared PV, when nothing has bound this one: the case that
# looped. A bound PV is left alone - the run below still meets an existing
# PV, which is the code path either way.
if [ -z "$(k get pv kinc-shared -o jsonpath='{.spec.claimRef.name}' 2>/dev/null)" ]; then
    k delete pv kinc-shared --wait=true >/dev/null 2>&1 || true
    k create -f - >/dev/null <<'EOF'
apiVersion: v1
kind: PersistentVolume
metadata:
  name: kinc-shared
spec:
  capacity: {storage: 100Gi}
  accessModes: [ReadWriteMany]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: kinc-shared
  hostPath: {path: /mnt/kinc-storage/shared, type: DirectoryOrCreate}
EOF
    echo "   kinc-shared replaced by one with an older image's hostPath"
fi
pv_before=$(k get pv kinc-shared -o jsonpath='{.metadata.uid} {.spec.hostPath.path}')

podman exec "$CP" rm -f /var/lib/kinc-initialized
podman exec "$CP" systemctl reset-failed kinc-postinit.service 2>/dev/null || true
if ! podman exec "$CP" systemctl restart kinc-postinit.service; then
    echo "❌ kinc-postinit failed when run again"
    podman exec "$CP" journalctl -u kinc-postinit.service --no-pager -n 40 || true
    exit 1
fi
podman exec "$CP" test -f /var/lib/kinc-initialized \
    || { echo "❌ kinc-postinit ran again but wrote no success marker"; exit 1; }
echo "✅ kinc-postinit succeeded when run again"

kp_after=$(gen daemonset/kube-proxy)
dns_after=$(gen deployment/coredns)
[ "$kp_after" = "$kp_before" ] \
    || { echo "❌ kube-proxy generation ${kp_before} -> ${kp_after}: the run rolled it on every node"; exit 1; }
[ "$dns_after" = "$dns_before" ] \
    || { echo "❌ coredns generation ${dns_before} -> ${dns_after}: the run rewrote it"; exit 1; }
echo "✅ kube-proxy (generation ${kp_after}) and coredns (${dns_after}) untouched"

pv_after=$(k get pv kinc-shared -o jsonpath='{.metadata.uid} {.spec.hostPath.path}')
[ "$pv_after" = "$pv_before" ] \
    || { echo "❌ kinc-shared changed: '${pv_before}' -> '${pv_after}'"; exit 1; }
echo "✅ the existing kinc-shared PV left as it was (${pv_after#* })"

podman exec "$CP" systemctl show kinc-postinit.service -p StartLimitIntervalUSec -p StartLimitBurst \
    | grep -qx 'StartLimitIntervalUSec=infinity' \
    || { echo "❌ kinc-postinit retries are not bounded (StartLimitIntervalSec)"; exit 1; }
echo "✅ kinc-postinit retries are bounded: 20 starts per boot"
