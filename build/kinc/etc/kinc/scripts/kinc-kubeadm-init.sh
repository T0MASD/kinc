#!/bin/bash
# kubeadm init, run as phases so the scheduler starts last.
#
# 'kubeadm init' writes all three control-plane manifests at once, so the
# scheduler starts at the same moment as the API server - before the API
# server's own RBAC bootstrap has created system:kube-scheduler's binding. The
# scheduler is then denied for about a second, which is every 403 in a healthy
# kinc bootstrap: measured at 52 of them, all inside the first second.
#
# Writing the scheduler's manifest after the API server is answering authorized
# requests removes the race rather than waiting it out.
#
# The order below is kubeadm's own, with 'control-plane scheduler' moved to the
# end. etcd is included because the API server has no datastore without it.
set -euo pipefail

CONFIG=/tmp/kubeadm-final.conf

# super-admin.conf, not admin.conf. admin.conf's user is cluster-admin by RBAC,
# and that binding is created by a later phase - so waiting on an RBAC object
# with it deadlocks: the check cannot run until the thing that authorises the
# check has happened. super-admin.conf's user is in system:masters, which the
# API server treats as cluster-admin directly, so it works before RBAC exists.
ADMIN=/etc/kubernetes/super-admin.conf

log() { echo "[$(date -u +%FT%T.%6NZ)] $*"; }
phase() { log "phase: $*"; kubeadm init phase "$@" --config="$CONFIG"; }

log "=== kubeadm init, phased ==="

phase certs all
phase kubeconfig all
phase etcd local
phase control-plane apiserver
phase control-plane controller-manager
phase kubelet-start

# Wait for an authorized request, not for /healthz. The API server answers
# health checks before the RBAC bootstrap has run, and it is exactly that
# bootstrap the scheduler is waiting on.
log "waiting for the API server to serve an authorized request..."
waited=0
until kubectl --kubeconfig="$ADMIN" get clusterrolebindings system:kube-scheduler >/dev/null 2>&1; do
    if [ "$waited" -ge 120 ]; then
        log "❌ system:kube-scheduler binding did not appear within ${waited}s"
        kubectl --kubeconfig="$ADMIN" get clusterrolebindings 2>&1 | head -5 || true
        exit 1
    fi
    sleep 1
    waited=$((waited + 1))
done
log "✅ scheduler RBAC present (${waited}s)"

phase upload-config all
phase mark-control-plane
phase bootstrap-token
phase kubelet-finalize all

# Not `phase addon all`. CoreDNS is a workload, and at this point the cluster
# has no CNI - Antrea is installed by postinit, after this unit finishes.
# Creating it here schedules a pod into a cluster with no network provider, and
# it fails sandbox creation until Antrea writes its config:
#
#   no CNI configuration file in /etc/cni/net.d/. Has your network provider
#   started?
#
# Measured at 19 seconds and six errors. It recovers on its own, which is why
# it read as noise rather than as the ordering mistake it is: the same shape as
# starting the scheduler before its RBAC exists. postinit runs the phase once
# Antrea is ready.

# Last: its permissions now exist, so it starts into a cluster that will answer
# it.
phase control-plane scheduler

log "=== kubeadm init complete ==="
