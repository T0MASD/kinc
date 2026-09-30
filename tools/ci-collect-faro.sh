#!/usr/bin/env bash
# Collects Faro's captured events for each named cluster into artifacts/faro/.
#
# Usage: ci-collect-faro.sh <cluster> [more clusters]
#
# Read from the volume rather than through podman exec: the events are written
# to the cluster's own /var, so they are on the host filesystem already and
# survive the container being gone by collection time.
# Collection is best effort and says only what it found. It used to guess -
# "no Faro events (Faro not enabled for this cluster?)" - and the guess was
# wrong for an unknown number of runs while Faro was dying on startup. A
# question mark in a warning reads like a configuration note, which is how a
# broken observer went unnoticed. Whether Faro should have captured anything is
# ci-verify-faro.sh's to decide.
set -uo pipefail

echo "=== Collecting Faro events ==="

for cluster in "$@"; do
  src="${HOME}/.local/share/containers/storage/volumes/kinc-${cluster}-var-data/_data/lib/kinc/faro-events/logs"
  dst="artifacts/faro/${cluster}"

  if [ ! -d "$src" ]; then
    echo "   ${cluster}: no events directory at ${src}"
    continue
  fi
  if [ -z "$(ls -A "$src"/*.json 2>/dev/null)" ]; then
    echo "   ${cluster}: events directory exists but holds no .json"
    ls -la "$src" 2>&1 | sed 's/^/     /'
    continue
  fi

  mkdir -p "$dst"
  cp "$src"/*.json "$dst"/ 2>/dev/null
  cp "$src"/*.log  "$dst"/ 2>/dev/null

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
            | .[:10] | .[] | "      \(.n)\t\(.k)"' "$dst"/*.json 2>/dev/null
  echo "   by eventType:"
  jq -r -s 'group_by(.eventType) | map({k: .[0].eventType, n: length}) | sort_by(-.n)
            | .[] | "      \(.n)\t\(.k)"' "$dst"/*.json 2>/dev/null
done
