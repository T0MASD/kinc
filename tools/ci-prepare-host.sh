#!/usr/bin/env bash
# Prepares a CI runner to host a kinc cluster, then reports what it set.
#
# Both CI jobs call this. They used to carry a copy of these checks each, and
# the copies drifted: a change to one left the other enforcing a weaker
# contract while still reporting success.
set -euo pipefail

echo "=== System Prerequisites Check ==="
echo ""

# The commands deploy.sh runs. Checked here because it does not check them
# itself: absent, the first one reached kills the run with exit 127 and a log
# that stops mid-sentence, naming nothing.
#
# Found on a clean Fedora guest, where openssl and kubectl are simply not
# installed. It is invisible on a CI runner and on a developer workstation,
# which ship all of these, so the only host that ever sees it is the one the
# README's prerequisites section is written for.
echo "━━━ Check 0: Required Commands ━━━"
missing=""
for c in podman awk sed openssl kubectl numfmt; do
  if command -v "$c" >/dev/null 2>&1; then
    echo "  ✅ $c"
  else
    echo "  ❌ $c"
    missing="${missing} $c"
  fi
done
if [ -n "$missing" ]; then
  echo ""
  echo "❌ Missing:${missing}"
  echo "   On Fedora: sudo dnf install -y${missing// kubectl/ kubernetes-client}"
  exit 1
fi
echo ""

# Rootless kinc runs as systemd --user units, and a user manager is stopped when
# the user's last session ends unless lingering is enabled. Without it a cluster
# is destroyed on logout: deploy.sh reports success, the cluster is genuinely
# Ready, and `podman ps` is empty when you next log in, with nothing in any log
# because nothing failed.
#
# It does not show up where kinc is developed. A workstation stays logged in,
# and a CI job holds a session for its whole life.
echo "━━━ Check 0b: User Lingering ━━━"
if [ "$(loginctl show-user "$(id -un)" --property=Linger --value 2>/dev/null)" = "yes" ]; then
  echo "✅ Lingering: enabled for $(id -un)"
else
  echo "  Enabling, so the cluster outlives this session..."
  sudo loginctl enable-linger "$(id -un)"
  echo "✅ Lingering: enabled for $(id -un)"
fi

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
# jq is checked before it is used, because the fallback that used to stand in
# for it - `|| echo 0` - made a missing jq indistinguishable from a healthy
# machine: both printed "No failed services" and both passed. A prerequisite
# this check cannot run without is a failure of the check, not a result.
if ! command -v jq >/dev/null 2>&1; then
  echo "❌ jq is required to read the unit list (also used by tools/ci-verify-samemachine.sh)"
  exit 1
fi
failed=$(systemctl --user list-units --state=failed --output=json --no-pager 2>/dev/null | jq 'length')
if [ "${failed:-0}" -gt 0 ]; then
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
