#!/usr/bin/env bash
# Asserts that Faro, when it was asked for, is actually capturing.
#
# Usage: ci-verify-faro.sh <cluster> [more clusters]
#
# Deploying with KINC_ENABLE_FARO=true prints "enabling Faro event capture" and
# applies the manifest, and that is the last anyone hears about it. The pod can
# die a second later and the deploy still reports success, because applying a
# static pod manifest is all it claimed to do.
#
# It happened: the image declares USER faro and writes to a hostPath the kubelet
# creates root-owned, which worked only while the crun wrapper was deleting
# process.user from every OCI spec. When that stopped, Faro died on startup with
#
#   failed to create log directory: mkdir /var/faro/events/logs: permission denied
#
# and captured nothing for an unknown number of runs. Nothing noticed: the
# collector found no files and printed "no Faro events (Faro not enabled for
# this cluster?)" - a guess, and the wrong one, phrased as a question so it read
# like a configuration note rather than a failure.
#
# So: the pod must be running, and it must have written something. Presence is
# not the assertion - a pod can be Running and producing nothing, which is the
# state this gate exists to catch.
set -euo pipefail

status=0

for cluster in "$@"; do
  node="kinc-${cluster}-control-plane"
  echo "=== ${cluster}: Faro is capturing ==="

  # Only judge clusters that asked for it. A cluster deployed without Faro has
  # no manifest, and that is a configuration rather than a fault.
  if ! podman exec "$node" test -f /etc/kubernetes/manifests/faro-bootstrap.yaml 2>/dev/null; then
    echo "   ${cluster}: no Faro manifest, not asked for - skipping"
    continue
  fi

  # Asked of the node, not the API server. The gate has to work the same in a
  # job that runs two clusters, where each has its own kubeconfig and none is
  # ambient - the first version used kubectl and failed on localhost:8080. It
  # also means a Faro that died because the API server is unwell still reports
  # as Faro being down, rather than the gate being unable to ask.
  state=$(podman exec "$node" sh -c \
            'crictl ps -a --name faro -o json 2>/dev/null | jq -r ".containers[0].state // \"ABSENT\""' \
          2>/dev/null || echo "ABSENT")
  if [ "$state" != "CONTAINER_RUNNING" ]; then
    echo "❌ ${cluster}: Faro was enabled but its container is ${state}"
    podman exec "$node" sh -c \
      'id=$(crictl ps -a --name faro -q 2>/dev/null | head -1); [ -n "$id" ] && crictl logs --tail 10 "$id" 2>&1' \
      2>/dev/null | sed 's/^/     /'
    status=1
    continue
  fi
  echo "✅ ${cluster}: Faro container running"

  # Written something, not merely started. The events land on the cluster's own
  # /var, so this reads the file rather than asking anything.
  events=/var/lib/kinc/faro-events/logs
  deadline=$(( $(date +%s) + 60 ))
  n=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    n=$(podman exec "$node" sh -c "cat ${events}/*.json 2>/dev/null | wc -l" 2>/dev/null || echo 0)
    [ "${n:-0}" -gt 0 ] && break
    sleep 5
  done

  if [ "${n:-0}" -eq 0 ]; then
    echo "❌ ${cluster}: Faro is running but has captured nothing in 60s"
    podman exec "$node" sh -c \
      'id=$(crictl ps -a --name faro -q 2>/dev/null | head -1); [ -n "$id" ] && crictl logs --tail 10 "$id" 2>&1' \
      2>/dev/null | sed 's/^/     /'
    podman exec "$node" sh -c "ls -la ${events} 2>&1" | sed 's/^/     /'
    status=1
    continue
  fi
  echo "✅ ${cluster}: ${n} events captured"
done

exit "$status"
