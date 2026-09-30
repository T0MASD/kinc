#!/usr/bin/env bash
# Asserts that no API denial was still recurring when the cluster was torn down.
#
# Usage: ci-verify-denials.sh <cluster> [more clusters]
#
# Reads the archived audit log, after teardown. Not a stylistic choice - the
# question cannot be answered any earlier. Whether something has stopped is
# only visible once enough silence has accumulated to outlast its own period,
# and asked against a live cluster the newest denial is always seconds old:
# local-path's helper pod is denied four times a second apart, and three
# seconds later "stopped" and "about to fire again" are indistinguishable. The
# live gate failed on exactly that, twice, at two different thresholds.
#
# Against a finished record there is no such ambiguity. The burst is a minute
# old by teardown, a fault that never stopped is still firing at the end, and
# both are plain.
#
# A component starting before its ServiceAccount token is projected, or before
# kubeadm created its bindings, is denied until that resolves and then
# succeeds. So is a kubelet still syncing status for a pod that has just been
# deleted: the Node authorizer drops the node->pod edge with the object, and
# authorization runs ahead of the storage lookup, so the API answers Forbidden
# where NotFound would be the truth. A misconfigured component is denied the
# same way and never stops. The difference is persistence, not presence.
#
#   still recurring when quiet <= 3 * median(gap), over distinct timestamps
#
# No constant in it. Every fixed term tried here was wrong the same way: a 30s
# grace called a simultaneous pair 28s old "recurring", because a widest gap of
# zero leaves a window made of nothing but grace; a 10s floor then called a 1s
# burst with 5s of silence recurring, one size down. Silence several times
# longer than the period is silence.
#
# Median, not widest, and over distinct timestamps. Denials group by caller,
# verb and resource, so every local-path helper pod lands in one class: two
# short bursts twenty-three seconds apart gave a widest gap of 23s and read as
# a twenty-three-second cadence, which failed a healthy run. The typical gap
# describes what the class does; the largest one describes the space between
# two things it did. Simultaneous entries collapse first, because firing twice
# in the same second is one occurrence, not a zero-second period.
set -euo pipefail

status=0

for cluster in "$@"; do
  log="artifacts/audit/${cluster}/audit.log"

  # No log means audit was off for this cluster, which is a configuration
  # rather than a fault - ci-verify-audit-off.sh is what asserts that.
  if [ ! -s "$log" ]; then
    echo "   ${cluster}: no audit log collected (audit off for this cluster)"
    continue
  fi

  echo "=== ${cluster}: denials in the finished record ==="

  # The end of observation: the last thing the API server recorded.
  end=$(jq -r '.requestReceivedTimestamp' "$log" | sort | awk 'END { print }')
  if [ -z "$end" ]; then
    echo "❌ ${cluster}: audit log carries no timestamps"
    status=1
    continue
  fi
  end_epoch=$(date -u -d "$end" +%s)

  denials=$(jq -r '
    select((.responseStatus.code // 200) == 403)
    | ((if .impersonatedUser then .impersonatedUser.username else .user.username end)
       + "\t" + .verb + "\t" + (.objectRef.resource // "-"))
      + "\t" + .requestReceivedTimestamp' "$log")

  if [ -z "$denials" ]; then
    echo "✅ ${cluster}: no denials at all"
    continue
  fi

  recurring=""
  stopped=""
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    times=$(printf '%s\n' "$denials" \
            | awk -F'\t' -v k="$key" '($1 "\t" $2 "\t" $3) == k { print $4 }' \
            | while read -r ts; do date -u -d "$ts" +%s; done | sort -n -u)
    count=$(printf '%s\n' "$times" | grep -c .)
    last=$(printf '%s\n' "$times" | tail -1)
    quiet=$(( end_epoch - last ))

    if [ "$count" -le 1 ]; then
      stopped="${stopped}${key}\t(once, ${quiet}s before the end)"$'\n'
      continue
    fi

    period=$(printf '%s\n' "$times" | awk 'NR>1 { print $1 - prev } { prev = $1 }' \
             | sort -n | awk '{ g[NR] = $1 } END { print (NR ? g[int((NR+1)/2)] : 0) }' )
    if [ "$quiet" -le $(( 3 * period )) ]; then
      recurring="${recurring}${key}\tx${count}, every ${period}s typically, still going at the end"$'\n'
    else
      stopped="${stopped}${key}\tx${count}, stopped ${quiet}s before the end"$'\n'
    fi
  done < <(printf '%s\n' "$denials" | cut -f1-3 | sort -u | grep .)

  if [ -n "$recurring" ]; then
    echo "❌ ${cluster}: denials still recurring when the cluster was torn down:"
    printf '%b' "$recurring" | while IFS=$'\t' read -r who verb res detail; do
      echo "   ${verb} ${res} by ${who}: ${detail}"
    done
    status=1
  fi

  if [ -n "$stopped" ]; then
    echo "✅ ${cluster}: every denial stopped:"
    printf '%b' "$stopped" | while IFS=$'\t' read -r who verb res detail; do
      echo "      ${verb} ${res} by ${who} - ${detail}"
    done
  fi
done

exit "$status"
