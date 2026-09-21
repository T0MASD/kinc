#!/usr/bin/env bash
# Prepares a CI runner to host a kinc cluster, then reports what it set.
#
# Both CI jobs call this. They used to carry a copy of these checks each, and
# the copies drifted: a change to one left the other enforcing a weaker
# contract while still reporting success.
set -euo pipefail

echo "=== System Prerequisites Check ==="

echo "━━━ Check 1: IP Forwarding ━━━"
if [ "$(cat /proc/sys/net/ipv4/ip_forward)" != "1" ]; then
  echo "Enabling IP forwarding..."
  echo 1 | sudo tee /proc/sys/net/ipv4/ip_forward
fi
echo "✅ IP forwarding: enabled"
echo ""

echo "━━━ Check 2: Inotify Limits ━━━"
echo "  Current max_user_watches:   $(cat /proc/sys/fs/inotify/max_user_watches)"
echo "  Current max_user_instances: $(cat /proc/sys/fs/inotify/max_user_instances)"
echo "Setting inotify limits for multi-cluster testing..."
echo 524288 | sudo tee /proc/sys/fs/inotify/max_user_watches > /dev/null
echo 2048 | sudo tee /proc/sys/fs/inotify/max_user_instances > /dev/null
echo "✅ Inotify limits: configured (watches=524288, instances=2048)"
echo ""

echo "━━━ Check 3: Kernel Keyring Limits ━━━"
echo "  Current maxkeys:   $(cat /proc/sys/kernel/keys/maxkeys 2>/dev/null || echo 'N/A')"
echo "  Current maxbytes:  $(cat /proc/sys/kernel/keys/maxbytes 2>/dev/null || echo 'N/A')"
echo "Setting kernel keyring limits for multi-cluster testing..."
echo 1000 | sudo tee /proc/sys/kernel/keys/maxkeys > /dev/null
echo 25000 | sudo tee /proc/sys/kernel/keys/maxbytes > /dev/null
echo "✅ Kernel keyring limits: configured (maxkeys=1000, maxbytes=25000)"
echo ""

# Antrea's datapath is Open vSwitch, and geneve encapsulates traffic between
# nodes. A rootless nested container cannot load a kernel module itself, so the
# host loads them - exactly as a user does on their own machine. Both are
# required so a multi-node cluster built on kinc works, not only the
# single-node case CI exercises.
#
# A module compiled into the kernel is available without appearing in
# /sys/module, so modules.builtin is consulted too: checking only /sys/module
# reports a builtin geneve as missing.
echo "━━━ Check 4: Antrea Kernel Modules ━━━"
sudo modprobe openvswitch || true
sudo modprobe geneve || true
for m in openvswitch geneve; do
  if [ -d "/sys/module/$m" ]; then
    echo "  $m loaded"
  elif grep -qw "$m" "/lib/modules/$(uname -r)/modules.builtin" 2>/dev/null; then
    echo "  $m builtin"
  else
    echo "❌ $m is neither loaded nor builtin"
    exit 1
  fi
done
echo "✅ Antrea kernel modules: openvswitch, geneve"
echo ""

# The Pod /var volume must sit on a shared mount, so network namespaces created
# inside the cluster container are visible to Antrea's agent. Podman keeps
# rootless volumes under the user's home.
echo "━━━ Check 5: Mount Propagation ━━━"
volroot="$HOME/.local/share/containers/storage"
mkdir -p "$volroot"
target=$(findmnt -no TARGET --target "$volroot" | head -1)
sudo mount --make-rshared "$target"
echo "✅ $target is $(findmnt -no PROPAGATION --target "$volroot")"
echo ""

echo "━━━ Check 6: System Health ━━━"
failed=$(systemctl --user list-units --state=failed --output=json --no-pager 2>/dev/null | jq 'length' 2>/dev/null || echo 0)
if [ "$failed" -gt 0 ]; then
  echo "⚠️  Found $failed failed services"
  systemctl --user list-units --state=failed --no-pager
else
  echo "✅ No failed services"
fi
echo ""

echo "━━━ Check 7: Podman ━━━"
echo "✅ Podman: $(podman --version)"
echo ""

echo "✅ Prerequisites check complete"
