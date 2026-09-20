#!/usr/bin/env bash
# Asserts that each init service reached its milestone, for every cluster named
# on the command line.
#
# The source of truth is /var/log/kinc/<unit>.log, not the journal. kubeadm-init
# sends its output to that file with StandardOutput=append:, which replaces
# journal output rather than adding to it, so kubeadm's account of building the
# cluster is not in the journal at all. Reading the file works for every unit
# here and survives the container, which the journal does not.
#
# Markers are matched with bash substring tests. Piping into grep -q makes the
# reader exit on its first match and SIGPIPE the producer, which -o pipefail
# then reports as failure for a marker that is present.
set -euo pipefail

wait_for_marker() {
  local cluster="$1" unit="$2" marker="$3" timeout="${4:-120}" waited=0 content
  local file="/var/log/kinc/${unit%.service}.log"
  while [ "$waited" -lt "$timeout" ]; do
    content=$(podman exec "kinc-${cluster}-control-plane" cat "$file" 2>/dev/null || true)
    if [ "${content#*"$marker"}" != "$content" ]; then
      if [ "$waited" -gt 0 ]; then echo "   (appeared after ${waited}s)"; fi
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done
  echo "❌ '$marker' not found in $file on cluster '$cluster' after ${timeout}s"
  podman exec "kinc-${cluster}-control-plane" systemctl status "$unit" --no-pager || true
  podman exec "kinc-${cluster}-control-plane" cat "$file" || true
  podman exec "kinc-${cluster}-control-plane" journalctl -u "$unit" --no-pager --boot || true
  return 1
}

echo "=== Verifying Configuration Validation ==="

for cluster in "$@"; do
  echo ""
  echo "Checking cluster: $cluster"

  wait_for_marker "$cluster" kinc-preflight.service "Configuration validated"
  echo "✅ Configuration validated by kinc-preflight.service"

  # We skip the show-join-command phase, so check for addon installation
  wait_for_marker "$cluster" kubeadm-init.service "Applied essential addon: kube-proxy"
  echo "✅ kubeadm init completed successfully (as systemd service)"

  wait_for_marker "$cluster" kinc-postinit.service "Installing CNI"
  echo "✅ CNI installed by kinc-postinit.service"

  echo "✅ Cluster '$cluster': All configuration validations passed"
done

echo ""
echo "✅ All configuration validations passed"
