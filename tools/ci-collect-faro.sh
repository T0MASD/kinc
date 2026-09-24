#!/usr/bin/env bash
# Collects Faro's captured events for each named cluster into artifacts/faro/.
#
# Usage: ci-collect-faro.sh <cluster> [more clusters]
#
# Read from the volume rather than through podman exec: the events are written
# to the cluster's own /var, so they are on the host filesystem already and
# survive the container being gone by collection time.
set -euo pipefail

echo "=== Collecting Faro events ==="

for cluster in "$@"; do
  src="${HOME}/.local/share/containers/storage/volumes/kinc-${cluster}-var-data/_data/lib/kinc/faro-events/logs"
  dst="artifacts/faro/${cluster}"

  if [ ! -d "$src" ] || [ -z "$(ls -A "$src"/*.json 2>/dev/null)" ]; then
    echo "⚠️  ${cluster}: no Faro events (Faro not enabled for this cluster?)"
    continue
  fi

  mkdir -p "$dst"
  cp "$src"/*.json "$dst"/ 2>/dev/null || true
  cp "$src"/*.log  "$dst"/ 2>/dev/null || true

  # Count objects, not lines, so a truncated capture is reported rather than
  # counted as events.
  if n=$(jq -s 'length' "$dst"/*.json 2>/dev/null); then
    echo "✅ ${cluster}: ${n} events"
  else
    echo "⚠️  ${cluster}: event file is not valid JSON"
    continue
  fi

  # Grouped in jq rather than sort | uniq -c | head, which exits early and
  # SIGPIPEs its producer under -o pipefail.
  echo "   by type:"
  jq -r -s 'group_by(.gvr) | map({k: .[0].gvr, n: length}) | sort_by(-.n)
            | .[:10] | .[] | "      \(.n)\t\(.k)"' "$dst"/*.json 2>/dev/null || true
  echo "   by eventType:"
  jq -r -s 'group_by(.eventType) | map({k: .[0].eventType, n: length}) | sort_by(-.n)
            | .[] | "      \(.n)\t\(.k)"' "$dst"/*.json 2>/dev/null || true
done
