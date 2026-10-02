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

# Every placeholder the templates carry has to be substituted by preflight, or
# it reaches kubeadm verbatim: PLACEHOLDER is not valid in any field that takes
# one, so this surfaces as a parse error or a node advertising a literal string.
PREFLIGHT=build/kinc/etc/kinc/scripts/kinc-preflight.sh
for ph in $(grep -ohE '[A-Z_]+_PLACEHOLDER' "$BAKED" "$MOUNTED" | sort -u); do
    if grep -q "$ph" "$PREFLIGHT"; then
        echo "✅ ${ph} is substituted"
    else
        echo "❌ ${ph} appears in a template but nothing in preflight substitutes it"
        fail=1
    fi
done

exit $fail
