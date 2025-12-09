                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    #!/bin/bash
set -euo pipefail

echo "🏗️ kinc Container Image Build"
echo "============================="

# Single image for all clusters (no cluster name in tag)
# Build once, deploy many times with different configs
# Note: Update this when upgrading Kubernetes version
IMAGE_NAME="localhost/kinc/node:v1.34.2"

# Cache busting for package updates (increment when packages need updating)
CACHE_BUST="${CACHE_BUST:-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

echo "🏷️  Building image: $IMAGE_NAME"
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

# Validation: Check that our configuration infrastructure is in place
echo
echo "🔍 Validating Checking configuration infrastructure..."

# Check that config directory exists
if podman run --rm --entrypoint /bin/sh "$IMAGE_NAME" -c "test -d /etc/kinc/config"; then
    echo "✅ Configuration directory exists: /etc/kinc/config"
else
    echo "❌ Configuration directory missing: /etc/kinc/config"
    exit 1
fi

# Check that baked-in configuration exists 
if podman run --rm --entrypoint /bin/sh "$IMAGE_NAME" -c "test -f /etc/kinc/kubeadm.conf"; then
    echo "✅ Baked-in configuration exists: /etc/kinc/kubeadm.conf"
else
    echo "❌ Baked-in configuration missing: /etc/kinc/kubeadm.conf"
    exit 1
fi

# Validate that the baked-in config is valid YAML
echo "🔍 Validating baked-in configuration YAML..."
if podman run --rm --entrypoint /bin/sh "$IMAGE_NAME" -c 'command -v yq >/dev/null 2>&1 && yq eval . /etc/kinc/kubeadm.conf >/dev/null 2>&1'; then
    echo "✅ Baked-in configuration is valid YAML"
elif podman run --rm --entrypoint /bin/sh "$IMAGE_NAME" -c 'python3 -c "import yaml; yaml.safe_load(open(\"/etc/kinc/kubeadm.conf\"))" 2>/dev/null'; then
    echo "✅ Baked-in configuration is valid YAML (validated with Python)"
else
    echo "⚠️  Could not validate YAML (yq/python not available), but config exists"
fi

# Check that enhanced init script exists and has our new functions
if podman run --rm --entrypoint /bin/sh "$IMAGE_NAME" -c "grep -q 'validate_configuration' /etc/kinc/scripts/kinc-init.sh"; then
    echo "✅ Enhanced init script with validation functions"
else
    echo "❌ Init script missing validation functions"
    exit 1
fi

if podman run --rm --entrypoint /bin/sh "$IMAGE_NAME" -c "grep -q 'setup_configuration' /etc/kinc/scripts/kinc-init.sh"; then
    echo "✅ Enhanced init script with configuration setup"
else
    echo "❌ Init script missing configuration setup functions"
    exit 1
fi

echo "✅ Validation complete - Baked-in configuration active!"

# Show image size
echo
echo "📊 Image information:"
podman images | grep "kinc/node.*v1.34"

echo
echo "🚀 Next steps:"
echo "  1. Deploy default: ./tools/deploy.sh"
echo "  2. Deploy custom:  CLUSTER_NAME=stage ./tools/deploy.sh"
echo "  3. Test:           CLUSTER_NAME=default ./tools/test.sh"
echo "  4. Clean:          CLUSTER_NAME=default ./tools/cleanup.sh"
echo

echo "💡 Baked-in Config with Override:"
echo "  - Build ONCE: ./tools/build.sh (includes default config)"
echo "  - Deploy default: CLUSTER_NAME=<name> ./tools/deploy.sh"
echo "  - Override config: Mount custom config volume (optional)"
echo "  - Use CACHE_BUST=2 ./tools/build.sh to force package updates"