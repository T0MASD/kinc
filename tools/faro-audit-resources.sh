#!/usr/bin/env bash
# Prints the audit resource list that matches what Faro watches, as
# KINC_AUDIT_RESOURCES expects it: comma-separated "<group>/<resource>".
#
# Derived from Faro's own config rather than restated, so the two cannot drift:
# Faro records what changed and audit records what was read, and a resource
# watched by one and not the other leaves half the question unanswerable.
#
# Faro states a GVR as "[group/]version/resource"; audit wants group and
# resource with the version dropped, and the core group written as empty
# ("v1/pods" -> "/pods").
set -euo pipefail

CONFIG="${1:-build/kinc/etc/faro/config.yaml}"

[ -f "$CONFIG" ] || { echo "no such Faro config: $CONFIG" >&2; exit 1; }

# Checked rather than assumed, because of how this is called. The caller writes
#
#     export KINC_AUDIT_RESOURCES="$(./tools/faro-audit-resources.sh)"
#
# and a command substitution that fails does not stop an assignment: the
# variable is simply empty, preflight reports "KINC_AUDIT_RESOURCES not set",
# and the API server starts with no audit flags at all. The cluster comes up
# healthy and records nothing, which is the one outcome an audit setup must not
# produce quietly.
command -v yq >/dev/null 2>&1 || {
  echo "yq is required to read ${CONFIG}" >&2
  exit 1
}

{
  # Cluster-scoped entries.
  yq eval '.resources[].gvr' "$CONFIG"
  # Namespaced entries, which are keys under each namespace's resources map.
  yq eval '.namespaces[].resources | keys | .[]' "$CONFIG"
} | sed '/^null$/d' | while read -r gvr; do
      [ -z "$gvr" ] && continue
      resource="${gvr##*/}"
      rest="${gvr%/*}"          # drops the resource, leaving [group/]version
      if [[ "$rest" == */* ]]; then
        group="${rest%/*}"      # drops the version, leaving the group
      else
        group=""                # only a version remained: the core group
      fi
      echo "${group}/${resource}"
    done | sort -u | paste -sd,
