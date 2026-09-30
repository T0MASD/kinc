#!/usr/bin/env bash
# Collects the API-server audit log of each named cluster into artifacts/audit/.
#
# Usage: ci-collect-audit.sh <cluster> [more clusters]
#
# Read from the volume rather than through podman exec, like the Faro events
# are: the log lives on the cluster's own /var volume, so it is on the host
# filesystem already and survives the container being gone by collection time.
set -euo pipefail

echo "=== Collecting API-server audit logs ==="

for cluster in "$@"; do
  src="${HOME}/.local/share/containers/storage/volumes/kinc-${cluster}-var-data/_data/log/kubernetes/audit"
  dst="artifacts/audit/${cluster}"

  if [ ! -f "${src}/audit.log" ]; then
    echo "⚠️  ${cluster}: no audit log (audit not enabled for this cluster?)"
    continue
  fi

  mkdir -p "$dst"
  # Rotated files too: --audit-log-maxbackup keeps up to 10 beside the live one.
  cp "${src}"/audit.log* "$dst"/ 2>/dev/null || true

  # Count entries as JSON objects, not lines, so a truncated capture is
  # reported rather than counted.
  if n=$(jq -s 'length' "${dst}/audit.log" 2>/dev/null); then
    echo "✅ ${cluster}: ${n} audit entries"
  else
    echo "⚠️  ${cluster}: audit log is not valid JSON"
    continue
  fi

  # A summary worth reading in the run log itself. Grouped in jq rather than
  # sort | uniq -c | head, which exits early and SIGPIPEs its producer under
  # -o pipefail.
  echo "   by verb:"
  jq -r -s 'group_by(.verb) | map({k: .[0].verb, n: length}) | sort_by(-.n)
            | .[] | "      \(.n)\t\(.k)"' "${dst}/audit.log" 2>/dev/null || true
  echo "   by resource:"
  jq -r -s 'group_by(.objectRef.resource) | map({k: (.[0].objectRef.resource // "none"), n: length})
            | sort_by(-.n) | .[:10] | .[] | "      \(.n)\t\(.k)"' "${dst}/audit.log" 2>/dev/null || true
  echo "   readers:"
  jq -r -s 'group_by(.user.username) | map({k: .[0].user.username, n: length})
            | sort_by(-.n) | .[:10] | .[] | "      \(.n)\t\(.k)"' "${dst}/audit.log" 2>/dev/null || true
done
