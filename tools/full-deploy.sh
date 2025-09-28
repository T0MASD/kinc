#!/bin/bash
set -euo pipefail

echo "🚀 kinc Full Deployment with Monitoring"
echo "======================================="

# Configuration: Cluster name (defaults to 'default')
CLUSTER_NAME="${CLUSTER_NAME:-default}"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

echo "🏷️  Cluster name: $CLUSTER_NAME"

print_phase() {
    echo
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}$1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Phase 0: Build
print_phase "PHASE 0: BUILD"
CLUSTER_NAME=${CLUSTER_NAME} ./tools/build.sh

# Phase 1: Cleanup
print_phase "PHASE 1: CLEANUP"
CLUSTER_NAME=${CLUSTER_NAME} ./tools/cleanup.sh

# Phase 2: Deploy
print_phase "PHASE 2: DEPLOY"
CLUSTER_NAME=${CLUSTER_NAME} ./tools/deploy.sh

# Phase 3: Monitor
print_phase "PHASE 3: MONITOR INITIALIZATION"
CLUSTER_NAME=${CLUSTER_NAME} ./tools/monitor.sh

# Phase 4: Test
print_phase "PHASE 4: RUN TESTS"
CLUSTER_NAME=${CLUSTER_NAME} ./tools/test.sh

# Phase 5: Untag (optional cleanup)
echo
echo "🧹 Untagging image localhost/kinc/node:v1.33.5-${CLUSTER_NAME}"
podman untag localhost/kinc/node:v1.33.5-${CLUSTER_NAME} 2>/dev/null || true

echo
echo -e "${GREEN}🎉 Full deployment completed successfully!${NC}"
echo
echo "📊 Your kinc cluster is ready for use:"
echo "  - Node: kinc-control-plane (Ready)"
echo "  - CNI: kincnet (Pod networking enabled)"
echo "  - Storage: local-path-provisioner (Dynamic PV provisioning)"
echo "  - DNS: CoreDNS (Service discovery enabled)"
echo
echo "🔧 Management commands:"
echo "  - Monitor: CLUSTER_NAME=${CLUSTER_NAME} ./tools/monitor.sh"
echo "  - Test: CLUSTER_NAME=${CLUSTER_NAME} ./tools/test.sh"
echo "  - Cleanup: CLUSTER_NAME=${CLUSTER_NAME} ./tools/cleanup.sh"
