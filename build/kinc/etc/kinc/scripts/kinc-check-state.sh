#!/usr/bin/env bash
# Assert that the two halves of a cluster's state still share one lifetime.
#
# A cluster's state lives in two places with independent lifetimes:
#
#   /var/lib/kubeadm-initialized   the marker that says this cluster was built,
#                                  on the node's var volume
#   /etc/kubernetes/pki/ca.crt     the identity it was built with, on the
#                                  etc-kubernetes volume - or, for a consumer
#                                  that mounts it, on a share
#
# Every provisioning step is gated on the first and every one of them produces
# the second, so the two must be created and destroyed together. Nothing
# enforces that. `podman volume rm kinc-etc-kubernetes` on its own leaves the
# marker behind, and the result is a cluster that can never work again and never
# says why: kubeadm-init is skipped because the marker exists, the PKI it would
# have written is gone, and every component fails on certificates that are not
# there.
#
# This is checked here rather than in kinc-preflight.sh because preflight
# carries the same marker guard. In the state that matters - marker present, PKI
# missing - preflight does not run at all, so an assertion inside it cannot see
# the one case worth catching.
#
# Keyed on the content rather than on a volume existing, so it holds for
# consumers whose /etc/kubernetes is not a podman volume.
set -euo pipefail

MARKER=/var/lib/kubeadm-initialized
CA=/etc/kubernetes/pki/ca.crt

log() { echo "[kinc-check-state] $*"; }

have_marker=0; [[ -f "$MARKER" ]] && have_marker=1
have_ca=0;     [[ -s "$CA" ]]     && have_ca=1

if (( have_marker == 1 && have_ca == 0 )); then
    log "❌ this node was initialised but its cluster identity is gone"
    log "   ${MARKER} exists, so every provisioning step will be skipped."
    log "   ${CA} is missing, so there is nothing for them to have produced."
    log ""
    log "   The two live on volumes with independent lifetimes and must share one."
    log "   Removing the etc-kubernetes volume without the var volume does this."
    log "   Recover by removing both and letting the cluster rebuild:"
    log "     ./tools/cleanup.sh <cluster>"
    exit 1
fi

if (( have_marker == 0 && have_ca == 1 )); then
    # The other direction. Less final - kubeadm adopts an existing CA and mints
    # the rest - but the etcd data that went with it lived on the var volume
    # that is gone, so the cluster keeps its identity and loses its contents.
    # Named rather than failed: a consumer that pre-seeds a CA on purpose is in
    # exactly this state, and that is a supported way to build a cluster.
    log "⚠️  a cluster identity is present with no record of this node being initialised"
    log "   ${CA} exists but ${MARKER} does not."
    log "   If the var volume was replaced, etcd's data went with it and this will"
    log "   rebuild the cluster around the existing CA rather than resume it."
fi

exit 0
