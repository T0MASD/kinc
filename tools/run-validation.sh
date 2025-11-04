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
KINC_IMAGE="${KINC_IMAGE:-localhost/kinc/node:v1.33.5}"
echo "Using image: $KINC_IMAGE"
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

echo "Waiting for API server (5-10 seconds)..."
timeout 120 bash -c 'until curl -k https://localhost:6450/healthz 2>/dev/null; do sleep 2; done'
echo "✅ API server ready"

echo "Waiting for full initialization (~40 seconds)..."
sleep 40

echo "✅ T3 complete: direct-podman cluster (baked-in config)"
echo ""

# ============================================================================
# Summary
# ============================================================================
echo "╔════════════════════════════════════════════════════════════════════════════╗"
echo "║                    Deployment Complete - 7 Clusters                        ║"
echo "╚════════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "Cluster Inventory:"
echo "  • default         (deploy.sh + baked-in)   - Port 6443"
echo "  • cluster01       (deploy.sh + mounted)    - Port 6444"
echo "  • cluster02       (deploy.sh + mounted)    - Port 6445"
echo "  • cluster03       (deploy.sh + mounted)    - Port 6446"
echo "  • cluster04       (deploy.sh + mounted)    - Port 6447"
echo "  • cluster05       (deploy.sh + mounted)    - Port 6448"
echo "  • kinc-direct-podman (podman run + baked-in) - Port 6450"
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

