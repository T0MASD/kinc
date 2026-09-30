#!/usr/bin/env bash
#
# Fail if kinc's own code asks the API server for a deprecated type.
#
# The API server answers a deprecated request normally and attaches a Warning
# header, which kubectl prints to stderr and every script here ignores. So a
# deprecated call is invisible until the type is removed and the call starts
# failing, in a release nobody was expecting to break:
#
#   Warning: v1 Endpoints is deprecated in v1.33+; use discovery.k8s.io/v1
#   EndpointSlice
#
# That one was in this repo's own cross-node gate and in Faro's watch list, and
# CI printed it on every run for as long as both existed.
#
# This reads sources rather than a cluster, so it needs nothing running and
# reports the file and line to change.
#
# Vendored upstream manifests are not checked: what antrea-cni.yaml or
# local-path's RBAC asks for is theirs to change, and pinning a chart here to
# say so would go stale on the next bump.
set -euo pipefail

cd "$(dirname "$0")/.."

# Each entry: <extended regex> <TAB> <what to use instead>
DEPRECATED=$(cat <<'EOF'
(^|[^a-z.])v1/endpoints\b|get[[:space:]]+endpoints\b|"endpoints"[[:space:]]*:	discovery.k8s.io/v1 EndpointSlice
\bpolicy/v1beta1\b	policy/v1
\bextensions/v1beta1\b	apps/v1 or networking.k8s.io/v1
\bapiextensions\.k8s\.io/v1beta1\b	apiextensions.k8s.io/v1
\bautoscaling/v2beta[12]\b	autoscaling/v2
\bbatch/v1beta1\b	batch/v1
\bnode\.k8s\.io/v1beta1\b	node.k8s.io/v1
\bflowcontrol\.apiserver\.k8s\.io/v1beta[123]\b	flowcontrol.apiserver.k8s.io/v1
EOF
)

# kinc's own sources. Upstream manifests are vendored whole and excluded.
mapfile -t FILES < <(
    git ls-files \
        'tools/*.sh' \
        'build/kinc/etc/faro/*.yaml' \
        'build/kinc/etc/kubernetes/manifests/*.yaml' \
        'runtime/manifests/*.yaml' \
        '.github/workflows/*.yml' \
    | grep -v 'antrea-cni.yaml'
)

found=0
while IFS=$'\t' read -r pattern replacement; do
    [ -n "$pattern" ] || continue
    while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        # A line that names the replacement is describing it, not calling it.
        printf '%s' "$hit" | grep -qF "$replacement" && continue
        echo "❌ ${hit}"
        echo "   use ${replacement}"
        found=$((found + 1))
    done < <(grep -nEI "$pattern" "${FILES[@]}" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
done <<< "$DEPRECATED"

if [ "$found" -gt 0 ]; then
    echo
    echo "❌ ${found} call(s) to deprecated Kubernetes APIs in kinc's own sources"
    exit 1
fi

echo "✅ no deprecated Kubernetes APIs in kinc's own sources (${#FILES[@]} files)"
