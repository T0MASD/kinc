#!/bin/bash
set -euo pipefail

echo "🎯 kinc Registry Image Usage Example"
echo "===================================="

# Configuration
KINC_IMAGE="${KINC_IMAGE:-ghcr.io/t0masd/kinc:v1.33.5}"
CLUSTER_NAME="${CLUSTER_NAME:-demo}"

echo "📥 Using registry image: $KINC_IMAGE"
echo "🏷️  Cluster name: $CLUSTER_NAME"
echo

# Check if image exists
echo "🔍 Checking if image is available..."
if ! podman pull "$KINC_IMAGE" --quiet; then
    echo "❌ Failed to pull image: $KINC_IMAGE"
    echo "   Make sure the image exists and you have access to it"
    echo "   Available images: https://github.com/T0MASD/kinc/pkgs/container/kinc"
    exit 1
fi
echo "✅ Image available"

# Deploy using registry image
echo
echo "🚀 Deploying kinc cluster using registry image..."
cd "$(dirname "$0")/.."

# Use registry image for deployment
export KINC_IMAGE="$KINC_IMAGE"
export CLUSTER_NAME="$CLUSTER_NAME"

# Deploy cluster
./tools/deploy.sh

# Monitor cluster startup
echo
echo "⏳ Waiting for cluster to be ready..."
timeout 300 ./tools/monitor.sh

# Extract kubeconfig
echo
echo "📋 Extracting kubeconfig..."
mkdir -p ~/.kube

# Get the actual port
CLUSTER_PORT=$(podman inspect kinc-${CLUSTER_NAME}-control-plane --format '{{range $p, $conf := .NetworkSettings.Ports}}{{range $conf}}{{.HostPort}}{{end}}{{end}}')

# Extract and configure kubeconfig
podman cp kinc-${CLUSTER_NAME}-control-plane:/etc/kubernetes/admin.conf ~/.kube/config-kinc-${CLUSTER_NAME}
sed -i "s|server: https://.*:6443|server: https://127.0.0.1:$CLUSTER_PORT|g" ~/.kube/config-kinc-${CLUSTER_NAME}

echo "✅ Kubeconfig saved to: ~/.kube/config-kinc-${CLUSTER_NAME}"
echo "   Port: $CLUSTER_PORT"

# Test cluster
echo
echo "🧪 Testing cluster..."
export KUBECONFIG=~/.kube/config-kinc-${CLUSTER_NAME}

echo "Nodes:"
kubectl get nodes -o wide

echo
echo "System pods:"
kubectl get pods -A

echo
echo "🎉 Success! kinc cluster is ready"
echo
echo "💡 Usage:"
echo "   export KUBECONFIG=~/.kube/config-kinc-${CLUSTER_NAME}"
echo "   kubectl get nodes"
echo
echo "🧹 Cleanup:"
echo "   CLUSTER_NAME=${CLUSTER_NAME} ./tools/cleanup.sh"
