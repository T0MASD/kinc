#!/bin/bash
set -euo pipefail

echo "🏗️ kinc Container Image Build"
echo "============================="

# Configuration: Cluster name
CLUSTER_NAME="${CLUSTER_NAME:-default}"
IMAGE_NAME="localhost/kinc/node:v1.33.5-${CLUSTER_NAME}"

# Cache busting for package updates (increment when packages need updating)
CACHE_BUST="${CACHE_BUST:-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

echo "🏷️  Building image: $IMAGE_NAME"
echo "🏷️  Cluster name: $CLUSTER_NAME"
echo "📁 Build context: $(pwd)"
echo "🔄 Cache bust level: $CACHE_BUST"

# Check if required Containerfile exists
if [ ! -f "build/Containerfile" ]; then
    echo "❌ Error: build/Containerfile not found"
    echo "   This file is required to build the image"
    exit 1
fi

echo
echo "🚀 Building consolidated image..."
echo "   This may take several minutes (downloading Fedora, installing packages)"
echo "   Using cache for unchanged layers (CACHE_BUST=$CACHE_BUST)"
cd build
podman build -f Containerfile -t "$IMAGE_NAME" --build-arg CACHE_BUST="$CACHE_BUST" .

echo
echo "✅ Build complete!"
echo "🏷️  Image built: $IMAGE_NAME"

# Verify the image
echo
echo "🔍 Verifying image..."
if ! podman images --format "{{.Repository}}:{{.Tag}}" | grep -q "^${IMAGE_NAME}$"; then
    echo "❌ Image verification failed"
    exit 1
fi

echo "✅ Image verified successfully!"

# Show image size
echo
echo "📊 Image information:"
podman images | grep "kinc/node" | grep "${CLUSTER_NAME}"

echo
echo "🚀 Next steps:"
echo "  1. Deploy: CLUSTER_NAME=${CLUSTER_NAME} ./tools/deploy.sh"
echo "  2. Test:   CLUSTER_NAME=${CLUSTER_NAME} ./tools/test.sh"
echo "  3. Clean:  CLUSTER_NAME=${CLUSTER_NAME} ./tools/cleanup.sh"
echo

echo "💡 Tips:"
echo "  - Use CLUSTER_NAME=mytest ./tools/build.sh for custom cluster names"
echo "  - Use CACHE_BUST=2 ./tools/build.sh to force package updates"
echo "  - The consolidated image includes all components in a single build"
echo "  - Layers are cached for faster rebuilds when only config changes"