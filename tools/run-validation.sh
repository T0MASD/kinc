#!/bin/bash
# kinc Validation Test - Automated Execution
# Tests baked-in and mounted configuration deployment methods
# References deployment commands from .github/workflows/release.yml

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "$PROJECT_ROOT"

echo "╔════════════════════════════════════════════════════════════════════════════╗"
echo "║              kinc Validation Test - Automated Execution                   ║"
echo "╚════════════════════════════════════════════════════════════════════════════╝"
echo ""

# Test configuration
KINC_IMAGE="${KINC_IMAGE:-localhost/kinc/node:v1.34.2}"
echo "Using image: $KINC_IMAGE"
echo ""

# ============================================================================
# Prerequisites: System Configuration Check
# ============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Prerequisites: System Configuration Check"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check 1: IP Forwarding (REQUIRED)
ip_forward=$(cat /proc/sys/net/ipv4/ip_forward)
if [ "$ip_forward" != "1" ]; then
  echo "❌ IP forwarding DISABLED"
  echo "   Required for Kubernetes pod networking!"
  echo "   Enable with: sudo sysctl -w net.ipv4.ip_forward=1"
  echo "   To persist:  echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.d/99-kinc.conf"
  exit 1
fi
echo "✅ IP forwarding enabled"

# Check 2: Inotify limits (REQUIRED for multi-cluster)
max_watches=$(cat /proc/sys/fs/inotify/max_user_watches)
max_instances=$(cat /proc/sys/fs/inotify/max_user_instances)
if [ "$max_watches" -lt 524288 ] || [ "$max_instances" -lt 2048 ]; then
  echo "❌ Inotify limits below recommended"
  echo "   Current: watches=$max_watches, instances=$max_instances"
  echo "   Recommended: watches=524288, instances=2048"
  echo "   Required for validation test (7 clusters)"
  echo "   To fix: sudo sysctl -w fs.inotify.max_user_watches=524288"
  echo "           sudo sysctl -w fs.inotify.max_user_instances=2048"
  echo "   Set KINC_SKIP_SYSCTL_CHECKS=true to bypass (not recommended)"
  [ "${KINC_SKIP_SYSCTL_CHECKS:-false}" != "true" ] && exit 1
fi
echo "✅ Inotify limits sufficient for 5+ clusters"

# Check 3: Kernel keyring limits (RECOMMENDED)
maxkeys=$(cat /proc/sys/kernel/keys/maxkeys 2>/dev/null || echo "1000")
maxbytes=$(cat /proc/sys/kernel/keys/maxbytes 2>/dev/null || echo "25000")
if [ "$maxkeys" -lt 1000 ] || [ "$maxbytes" -lt 25000 ]; then
  echo "⚠️  Kernel keyring limits below recommended"
  echo "   Current: maxkeys=$maxkeys, maxbytes=$maxbytes"
  echo "   Recommended: maxkeys=1000, maxbytes=25000"
  echo "   To fix: sudo sysctl -w kernel.keys.maxkeys=1000"
  echo "           sudo sysctl -w kernel.keys.maxbytes=25000"
else
  echo "✅ Kernel keyring limits sufficient"
fi

# Check 4: Failed services (WARNING only)
failed=$(systemctl --user list-units --state=failed --no-pager --no-legend 2>/dev/null | wc -l)
if [ $failed -gt 0 ]; then
  echo "⚠️  Found $failed failed user service(s) - review before testing"
  echo "   Check with: systemctl --user list-units --state=failed"
else
  echo "✅ System health: no failed services"
fi

echo ""
echo "✅ Prerequisites check complete"
echo ""

# ============================================================================
# T1: deploy.sh with baked-in config
# ============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "T1: Deploying with deploy.sh (baked-in config)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Deployment: See release.yml → Option 1"
echo ""

USE_BAKED_IN_CONFIG=true CLUSTER_NAME=default ./tools/deploy.sh
echo "✅ T1 complete: default cluster (baked-in config)"
echo ""

# ============================================================================
# T2: deploy.sh with mounted config (5 clusters)
# ============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "T2: Deploying with deploy.sh (mounted config - 5 clusters)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Deployment: See release.yml → Option 1 (without USE_BAKED_IN_CONFIG)"
echo ""

for i in 01 02 03 04 05; do
  echo "Deploying cluster${i}..."
  CLUSTER_NAME=cluster${i} ./tools/deploy.sh
  
  # Wait for service to be stable (systemd-driven, no arbitrary sleeps)
  echo "Verifying cluster${i} service stability..."
  until systemctl --user is-active --quiet kinc-cluster${i}-control-plane.service; do
    sleep 2
  done
  
  # Brief stability check
  sleep 2
  if systemctl --user is-failed --quiet kinc-cluster${i}-control-plane.service; then
    echo "❌ Service kinc-cluster${i}-control-plane.service has failed!"
    systemctl --user status kinc-cluster${i}-control-plane.service --no-pager
    exit 1
  fi
  
  echo "✅ cluster${i} deployed and stable"
  echo ""
done
echo "✅ T2 complete: 5 clusters with mounted config"
echo ""

# ============================================================================
# T3: direct podman run with baked-in config
# ============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "T3: Deploying with direct podman run (baked-in config)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Deployment: See release.yml → Option 2"
echo ""

# Clean any existing direct-podman cluster
podman rm -f kinc-direct-podman 2>/dev/null || true
podman volume rm kinc-direct-podman-var-data 2>/dev/null || true

# Create volume
podman volume create kinc-direct-podman-var-data

# Deploy using exact command from release.yml (Option 2)
# Modified: name=kinc-direct-podman, port=6450:6443
podman run -d --name kinc-direct-podman \
  --hostname kinc-direct-podman \
  --cgroups=split \
  --cap-add=SYS_ADMIN --cap-add=SYS_RESOURCE --cap-add=NET_ADMIN \
  --cap-add=SETPCAP --cap-add=NET_RAW --cap-add=SYS_PTRACE \
  --cap-add=DAC_OVERRIDE --cap-add=CHOWN --cap-add=FOWNER \
  --cap-add=FSETID --cap-add=KILL --cap-add=SETGID --cap-add=SETUID \
  --cap-add=NET_BIND_SERVICE --cap-add=SYS_CHROOT --cap-add=SETFCAP \
  --cap-add=DAC_READ_SEARCH --cap-add=AUDIT_WRITE \
  --device /dev/fuse \
  --tmpfs /tmp:rw,rprivate,nosuid,nodev,tmpcopyup \
  --tmpfs /run:rw,rprivate,nosuid,nodev,tmpcopyup \
  --tmpfs /run/lock:rw,rprivate,nosuid,nodev,tmpcopyup \
  --volume kinc-direct-podman-var-data:/var:rw \
  --volume $HOME/.local/share/containers/storage:/root/.local/share/containers/storage:rw \
  --sysctl net.ipv6.conf.all.disable_ipv6=0 \
  --sysctl net.ipv6.conf.all.keep_addr_on_down=1 \
  --sysctl net.netfilter.nf_conntrack_tcp_timeout_established=86400 \
  --sysctl net.netfilter.nf_conntrack_tcp_timeout_close_wait=3600 \
  -p 127.0.0.1:6450:6443/tcp \
  --env container=podman \
  "$KINC_IMAGE"

echo "Waiting for cluster initialization..."
timeout 300 bash -c 'until podman exec kinc-direct-podman test -f /var/lib/kinc-initialized 2>/dev/null; do sleep 2; done'
echo "✅ Cluster initialized"

echo "Waiting for API server to be ready (returns HTTP 200)..."
timeout 300 bash -c 'until curl -k -s -o /dev/null -w "%{http_code}" https://localhost:6450/healthz 2>/dev/null | grep -q "200"; do sleep 2; done'
echo "✅ API server responding"

echo "Waiting for system pods..."
kubectl --kubeconfig=<(podman exec kinc-direct-podman cat /etc/kubernetes/admin.conf | sed 's|server: https://.*:6443|server: https://127.0.0.1:6450|g') \
  wait --for=condition=Ready pods --all -n kube-system --timeout=300s

echo "Waiting for storage provisioner..."
# Wait for namespace to exist first (avoids "no matching resources" error)
timeout 60 bash -c 'until kubectl --kubeconfig=<(podman exec kinc-direct-podman cat /etc/kubernetes/admin.conf | sed "s|server: https://.*:6443|server: https://127.0.0.1:6450|g") get namespace local-path-storage >/dev/null 2>&1; do sleep 2; done'
# Wait for pods to be created
timeout 60 bash -c 'until kubectl --kubeconfig=<(podman exec kinc-direct-podman cat /etc/kubernetes/admin.conf | sed "s|server: https://.*:6443|server: https://127.0.0.1:6450|g") get pods -n local-path-storage 2>/dev/null | grep -q local-path-provisioner; do sleep 2; done'
# Now wait for pods to be ready
kubectl --kubeconfig=<(podman exec kinc-direct-podman cat /etc/kubernetes/admin.conf | sed 's|server: https://.*:6443|server: https://127.0.0.1:6450|g') \
  wait --for=condition=Ready pods --all -n local-path-storage --timeout=60s

echo "✅ T3 complete: direct-podman cluster (baked-in config)"
echo ""

# ============================================================================
# Verification: Multi-Service Architecture
# ============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Verification: Multi-Service Architecture"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check default cluster (baked-in config) as sample
echo "Checking default cluster multi-service architecture..."
verification_failed=false
for service in kinc-preflight.service kubeadm-init.service kinc-postinit.service; do
  if podman exec kinc-default-control-plane systemctl is-active --quiet $service 2>/dev/null; then
    echo "  ✅ $service: active"
  else
    echo "  ❌ $service: not active"
    verification_failed=true
  fi
done

if podman exec kinc-default-control-plane test -f /var/lib/kinc-initialized 2>/dev/null; then
  echo "  ✅ Initialization marker: present"
else
  echo "  ❌ Initialization marker: missing"
  verification_failed=true
fi

if [ "$verification_failed" = true ]; then
  echo "❌ Multi-service architecture verification failed"
  exit 1
fi

echo "✅ Multi-service architecture verified"
echo ""

# ============================================================================
# Summary
# ============================================================================
echo "╔════════════════════════════════════════════════════════════════════════════╗"
echo "║                    Deployment Complete - 7 Clusters                        ║"
echo "╚════════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "Cluster Inventory:"
podman ps --filter "name=kinc" --format "{{.Names}}\t{{.Status}}\t{{.Ports}}" | while IFS=$'\t' read -r name status ports; do
  # Skip empty lines
  if [ -z "$name" ]; then
    continue
  fi
  
  # Extract port from format: 127.0.0.1:6443->6443/tcp
  port=$(echo "$ports" | grep -oE '127\.0\.0\.1:[0-9]+' | cut -d: -f2 || echo "unknown")
  
  # Determine method
  if echo "$name" | grep -q "direct-podman"; then
    method="(podman run + baked-in)"
  elif [ "$name" = "kinc-default-control-plane" ]; then
    method="(deploy.sh + baked-in) "
  else
    method="(deploy.sh + mounted)  "
  fi
  
  # Format: adjust spacing based on name length
  printf "  • %-30s %s - Port %s\n" "$name" "$method" "$port"
done
echo ""

# Check if we should skip cleanup (for debugging)
if [[ "${SKIP_CLEANUP:-}" == "true" ]]; then
  echo "⚠️  SKIP_CLEANUP=true - Clusters left running for manual inspection"
  echo ""
  echo "Next: Run manual validation checks (see work/VALIDATION_TEST.md)"
  echo "  - kubectl get nodes (all clusters)"
  echo "  - kubectl get pods -A (all clusters)"
  echo "  - DNS, storage, and config source validation"
  echo ""
  echo "To cleanup later:"
  echo "  for cluster in default cluster01 cluster02 cluster03 cluster04 cluster05; do"
  echo "    CLUSTER_NAME=\$cluster ./tools/cleanup.sh"
  echo "  done"
  echo "  podman rm -f kinc-direct-podman"
  echo "  podman volume rm kinc-direct-podman-var-data"
  echo ""
  exit 0
fi

# Automatic cleanup
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Cleanup: Removing all validation test clusters"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

echo "Cleaning up deploy.sh clusters (6 clusters)..."
for cluster in default cluster01 cluster02 cluster03 cluster04 cluster05; do
  echo "  Cleaning $cluster..."
  CLUSTER_NAME=$cluster ./tools/cleanup.sh >/dev/null 2>&1 && echo "    ✅ $cluster removed" || echo "    ⚠️  $cluster cleanup failed"
done
echo ""

echo "Cleaning up direct podman run cluster..."
podman rm -f kinc-direct-podman >/dev/null 2>&1 && echo "  ✅ Container removed" || echo "  ⚠️  Container not found"
podman volume rm kinc-direct-podman-var-data >/dev/null 2>&1 && echo "  ✅ Volume removed" || echo "  ⚠️  Volume not found"
echo ""

echo "Verifying cleanup..."
REMAINING_CONTAINERS=$(podman ps -a --filter "name=kinc" --format "{{.Names}}" | wc -l)
REMAINING_VOLUMES=$(podman volume ls --filter "name=kinc" --format "{{.Name}}" | wc -l)

if [[ $REMAINING_CONTAINERS -eq 0 ]] && [[ $REMAINING_VOLUMES -eq 0 ]]; then
  echo "✅ All clusters cleaned up successfully"
else
  echo "⚠️  Warning: $REMAINING_CONTAINERS containers and $REMAINING_VOLUMES volumes remain"
fi
echo ""

echo "╔════════════════════════════════════════════════════════════════════════════╗"
echo "║                   ✅ VALIDATION TEST COMPLETE                              ║"
echo "╚════════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "All validation test clusters deployed, tested, and cleaned up."
echo ""
echo "To run without cleanup (for manual inspection), use:"
echo "  SKIP_CLEANUP=true ./tools/run-validation.sh"
echo ""

