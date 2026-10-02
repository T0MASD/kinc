#!/usr/bin/env bash
# The kubeadm config exists twice: baked into the image and mounted from the
# repo. A change applied to one and not the other does not fail anything - the
# cluster simply runs whichever copy that deployment used, so the same commit
# behaves differently depending on how it was deployed, and the two CI jobs
# that cover baked-in and mounted config disagree for no visible reason.
#
# Comments are stripped before comparing. They have drifted by 22 lines since
# before this check existed, and reconciling prose is not what this is for:
# what matters is that the two render the same cluster.
#
# Usage: ci-verify-config-drift.sh
set -uo pipefail

BAKED=build/kinc/etc/kinc/kubeadm.conf
MOUNTED=runtime/config/kubeadm.conf
fail=0

for f in "$BAKED" "$MOUNTED"; do
    [ -f "$f" ] || { echo "❌ missing $f"; exit 1; }
done

strip() { grep -vE '^[[:space:]]*#' "$1" | grep -vE '^[[:space:]]*$'; }

if diff -u <(strip "$BAKED") <(strip "$MOUNTED") > /tmp/kinc-config-drift.diff; then
    echo "✅ baked-in and mounted kubeadm.conf render the same cluster"
else
    echo "❌ baked-in and mounted kubeadm.conf disagree:"
    sed 's/^/    /' /tmp/kinc-config-drift.diff
    echo "    (apply the change to BOTH ${BAKED} and ${MOUNTED})"
    fail=1
fi

# Every placeholder any template carries has to be substituted by something, or
# it is written out verbatim: PLACEHOLDER is not valid in a kubeadm field, a
# systemd directive or a quadlet key, so it surfaces as a parse error, a unit
# that will not load, or a node advertising a literal string - none of which
# name the substitution that was missed.
#
# Templates are rendered by preflight (inside the node) and by the two tools
# that create nodes (on the host), so a placeholder is satisfied by any of them.
SUBSTITUTERS="build/kinc/etc/kinc/scripts/kinc-preflight.sh tools/deploy.sh tools/join-host.sh"
TEMPLATES="$BAKED $MOUNTED runtime/config/join.conf runtime/config/dropins/join.conf
           runtime/quadlet/kinc-control-plane.container runtime/quadlet/kinc-worker.container"

for ph in $(grep -ohE '[A-Z_0-9]+_PLACEHOLDER' $TEMPLATES 2>/dev/null | sort -u); do
    if grep -qh -- "$ph" $SUBSTITUTERS 2>/dev/null; then
        echo "✅ ${ph} is substituted"
    else
        echo "❌ ${ph} appears in a template but nothing substitutes it"
        fail=1
    fi
done

exit $fail
