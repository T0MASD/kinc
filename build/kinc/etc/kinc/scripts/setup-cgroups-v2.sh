#!/bin/bash
# kinc cgroup v2 setup script
# Ensures proper cgroup controller delegation for Kubernetes kubelet

set -euo pipefail

echo "=== kinc cgroup v2 setup starting ==="

# Check if we're running on cgroups v2
if [[ ! -f "/sys/fs/cgroup/cgroup.controllers" ]]; then
    echo "Not running on cgroups v2, skipping cgroup setup"
    exit 0
fi

echo "Setting up cgroup v2 controller delegation for kubelet..."

# Get available controllers from root cgroup
root_controllers=$(cat /sys/fs/cgroup/cgroup.controllers)
echo "Available root controllers: $root_controllers"

# Enable all available controllers at the root level for delegation
echo "Enabling controller delegation at root level..."

# First, try to enable all controllers
if echo "$root_controllers" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null; then
    echo "✅ Successfully enabled all controller delegation: $root_controllers"
else
    echo "⚠️  Could not enable all controllers at once, trying individual controllers..."
    
    # Try to enable controllers individually, focusing on the ones kubelet needs
    for controller in $root_controllers; do
        if echo "+$controller" >> /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null; then
            echo "✅ Enabled $controller controller"
        else
            echo "⚠️  Could not enable $controller controller (may already be in use)"
        fi
    done
fi

# Verify current enabled controllers
current_subtree=$(cat /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || echo "none")
echo "Currently enabled subtree controllers: $current_subtree"

# Verify what controllers are now available in systemd slices
echo "Checking controller availability in systemd slices..."
if [[ -f "/sys/fs/cgroup/system.slice/cgroup.controllers" ]]; then
    system_controllers=$(cat /sys/fs/cgroup/system.slice/cgroup.controllers)
    echo "System slice controllers: $system_controllers"
fi

if [[ -f "/sys/fs/cgroup/kubelet.slice/cgroup.controllers" ]]; then
    kubelet_controllers=$(cat /sys/fs/cgroup/kubelet.slice/cgroup.controllers)
    echo "Kubelet slice controllers: $kubelet_controllers"
    
    # Check if kubelet slice has the required controllers
    missing_controllers=""
    if [[ "$kubelet_controllers" == *"hugetlb"* ]]; then
        echo "✅ kubelet slice has hugetlb controller"
    else
        echo "❌ kubelet slice missing hugetlb controller"
        missing_controllers="$missing_controllers hugetlb"
    fi
    
    if [[ "$kubelet_controllers" == *"misc"* ]]; then
        echo "✅ kubelet slice has misc controller"
    else
        echo "❌ kubelet slice missing misc controller"
        missing_controllers="$missing_controllers misc"
    fi
    
    if [[ -n "$missing_controllers" ]]; then
        echo "⚠️  Some controllers are missing from kubelet.slice: $missing_controllers"
        echo "   This should be resolved when systemd creates the slice with proper delegation"
    else
        echo "✅ All required controllers are available in kubelet.slice"
    fi
else
    echo "⚠️  kubelet.slice not found yet (will be created by systemd when kubelet starts)"
    echo "   Controllers will be inherited from the enabled subtree delegation"
fi

echo "=== kinc cgroup v2 setup completed ==="
