#!/usr/bin/env bash
# Describes what a run's logs contain, as Markdown, without judging it.
#
# Usage: ci-summarize-run.sh [cluster] > artifacts/summary/<cluster>.md
#
# The gate answers pass/fail and says nothing about a green run. That leaves
# the interesting part unread: CI collects megabytes of journal and audit log
# per run and nobody opens them unless something already failed - by which time
# the question is "what broke", not "what changed".
#
# This is the shape the evidence takes when it is actually diagnosable. Every
# real conclusion in this repo came from one table - class, how far into the
# component's life it last appeared, how often, how long since - not from
# reading logs. The same table makes a fault obvious on sight:
#
#   kube-apiserver/controller.go:157      +45s   x12   216s ago   stopped
#   antrea-agent/route_linux.go:458      +158s    x5    36s ago   ONGOING
#
# It is deterministic and cheap, so it is safe to attach to every run, and it
# is the right input for anything that reads a run afterwards - a person
# skimming a job summary, or an agent asked whether anything looks wrong.
# Handing either one a 374KB journal instead is how you get a confident answer
# to a question nobody checked.
#
# Descriptive only. It exits 0 whatever it finds; the gates decide.
set -euo pipefail

# shellcheck source=tools/lib-component-logs.sh
. "$(dirname "$0")/lib-component-logs.sh"

CLUSTER="${1:-default}"
NODE="kinc-${CLUSTER}-control-plane"
# The same grace the gate applies, so the verdict column here means what a
# failure there would mean. Sourced from the gate's default rather than
# restated, since a summary that classified differently would be worse than none.
STARTUP=90
DETECTABLE_PERIOD=60
JUDGEABLE=$(( STARTUP + 2 * DETECTABLE_PERIOD ))
# Same contract as the gate: KINC_LOG_CAPTURE points at a capture taken before
# teardown, or absent, capture from the running cluster.
if [ -n "${KINC_LOG_CAPTURE:-}" ]; then
  CAP="$KINC_LOG_CAPTURE"
  OWN_CAP=0
else
  CAP="$(mktemp -d)"
  OWN_CAP=1
fi
trap '[ "$OWN_CAP" -eq 1 ] && rm -rf "$CAP"' EXIT

echo "## kinc run summary — cluster \`${CLUSTER}\`"
echo

# --- what was running ----------------------------------------------------
# Nodes, from the facts the collector wrote while the cluster existed, or from
# the cluster itself on a live run.
NODES_TSV=""
if [ "$OWN_CAP" -eq 0 ] && [ -s "$(dirname "$CAP")/nodes.tsv" ]; then
  NODES_TSV="$(dirname "$CAP")/nodes.tsv"
elif [ "$OWN_CAP" -eq 1 ]; then
  NODES_TSV="$(mktemp)"
  for n in $(kinc_nodes "$CLUSTER"); do
    started=$(podman inspect "$n" 2>/dev/null | jq -r '.[0].State.StartedAt')
    store=$(podman inspect "$n" 2>/dev/null \
            | jq -r '.[0].Mounts[] | select(.Destination=="/root/.local/share/containers/storage") | .Source')
    printf '%s\t%s\t%s\n' "$n" "$(( $(date +%s) - $(date -d "$started" +%s 2>/dev/null || echo 0) ))" "${store:-none}"
  done > "$NODES_TSV"
fi

if [ -n "$NODES_TSV" ] && [ -s "$NODES_TSV" ]; then
  echo "### Nodes"
  echo
  echo '```'
  while IFS=$'\t' read -r n age store; do
    echo "${n}  age=${age}s  store=${store}"
  done < "$NODES_TSV"
  echo '```'
  echo

  # Distinct stores must equal the node count. One store shared by two CRI-O
  # daemons is not a configuration choice: containers/storage is single-writer,
  # and each daemon garbage-collects the layers the other still references.
  stores=$(cut -f3 "$NODES_TSV" | sort -u | wc -l)
  nodes=$(wc -l < "$NODES_TSV")
  if [ "$stores" -ne "$nodes" ]; then
    echo "> **${nodes} nodes share ${stores} image store(s).** Each node needs its own:"
    echo "> two CRI-O daemons on one directory delete each other's layers, and the"
    echo "> loser runs containers whose lower layers are gone - lookups still resolve"
    echo "> from cache while readdir returns nothing."
    echo
  fi
fi

# --- error classes -------------------------------------------------------
# Pods and the nodes under them. A node's kubelet and CRI-O journal is where a
# fault lives that no Pod log can hold: a sandbox that was never created has no
# Pod to log to.
if [ "$OWN_CAP" -eq 1 ]; then
  kinc_capture_pod_logs  "$CAP" "$CLUSTER"
  kinc_capture_node_logs "$CAP" "$CLUSTER"
fi

if ! NOW=$(kinc_record_end "$CAP"); then
  echo "_No readable capture for this cluster._"
  exit 0
fi

echo "### Error classes"
echo
if [ "${KINC_UNREAD:-0}" -gt 0 ]; then
  echo "${KINC_UNREAD} pod director(ies) held no readable log at capture time."
  echo
fi
echo '| component | class | level | count | first | last | widest gap | quiet | state |'
echo '|---|---|:-:|---:|---:|---:|---:|---:|---|'

for f in "${CAP}"/*; do
  [ -s "$f" ] || continue
  t0_epoch="$(kinc_first_seen "$f")" || continue
  label="$(kinc_label "$(basename "$f")")"
  life=$(( NOW - t0_epoch ))

  kinc_class_lines "$f" > "${CAP}.errors"
  [ -s "${CAP}.errors" ] || continue

  while read -r cls; do
    [ -z "$cls" ] && continue
    awk -F'\t' -v c="$cls" '$2==c { print $1 }' "${CAP}.errors" \
      | while read -r ts; do date -d "$ts" +%s; done | sort -n -u > "${CAP}.times"

    # The highest severity this class was ever logged at, so a site that logs
    # both is reported by the worse of the two.
    sev=$(awk -F'\t' -v c="$cls" '$2==c { print $3 }' "${CAP}.errors" \
          | sort -u | awk '/F/{f=1} /E/{e=1} /W/{w=1}
                           END { print (f ? "F" : e ? "E" : w ? "W" : "?") }')

    count=$(wc -l < "${CAP}.times")
    first=$(head -1 "${CAP}.times")
    last=$(tail -1 "${CAP}.times")
    quiet=$(( NOW - last ))
    into=$(( last - t0_epoch ))
    maxgap=$(awk 'NR>1 { print $1 - prev } { prev = $1 }' "${CAP}.times" \
             | sort -n | awk '{ g[NR] = $1 } END { print (NR ? g[int((NR+1)/2)] : 0) }')

    # The gate's rule, reported rather than enforced: noisy while coming up is
    # allowed, still noisy afterwards is not, and "still" is measured against
    # the class's own cadence rather than a constant.
    # Same states the gate uses, including its floor on what counts as a
    # cadence: one interval between two events is an observation, not a rate,
    # so two occurrences are reported as two rather than extrapolated into
    # "still going". The gate fails on ONGOING, so the two must agree.
    if [ "$into" -le "$STARTUP" ]; then
      state='startup'
    elif [ "$count" -eq 1 ]; then
      state='once'
    elif [ "$count" -eq 2 ]; then
      state='twice'
    elif [ "$quiet" -le $(( 3 * maxgap )) ]; then
      state='**ONGOING**'
    else
      state='stopped'
    fi

    # Coverage is a property of the component, not a verdict on the class: a
    # class that stopped has stopped whatever its component's age. This marks
    # where a fault that has not appeared yet may simply not have had time to.
    if [ $(( life - STARTUP )) -lt $(( 2 * DETECTABLE_PERIOD )) ]; then
      thin=' ⚠'
    else
      thin=''
    fi

    printf '| %s%s | `%s` | %s | %s | +%ss | +%ss | %ss | %ss | %s |\n' \
      "$label" "$thin" "$cls" "$sev" "$count" "$(( first - t0_epoch ))" "$into" "$maxgap" "$quiet" "$state"
  done < <(cut -f2 "${CAP}.errors" | sort -u)
done
echo

# --- failed units --------------------------------------------------------
# What systemd itself thinks failed, per node.
#
# Nothing reported this, and three units failed on every node of every run:
# sys-kernel-config, -debug and -tracing, which a rootless container is not
# permitted to mount. They are masked now, so this is expected to be empty -
# which is the point. An empty list is only worth printing because a name in it
# means something.
#
# A failed unit leaves no klog line, so the table above cannot see it however
# wide it gets: systemd's verdict is not in any component's log.
echo "### Failed units"
echo
units_found=0
units_out=""
if [ "$OWN_CAP" -eq 1 ]; then
  for n in $(kinc_nodes "$CLUSTER"); do
    u=$(podman exec "$n" systemctl list-units --state=failed --no-legend --no-pager 2>/dev/null \
        | awk '{ print $2 }')
    if [ -n "$u" ]; then
      units_found=1
      units_out="${units_out}${n}:"$'\n'"$(printf '%s\n' "$u" | sed 's/^/  /')"$'\n'
    fi
  done
else
  for uf in "$(dirname "$CAP")"/nodes/*/failed-units.txt; do
    [ -s "$uf" ] || continue
    n=$(basename "$(dirname "$uf")")
    # A unit name, wherever it sits on the line: older captures carry
    # systemd's header and legend, and "UNIT LOAD ACTIVE SUB" parsed by column
    # reports a failed unit called LOAD.
    u=$(grep -oE '[A-Za-z0-9@:_.\\-]+\.(service|mount|socket|target|timer|path)' "$uf" \
        | sort -u || true)
    if [ -n "$u" ]; then
      units_found=1
      units_out="${units_out}${n}:"$'\n'"$(printf '%s\n' "$u" | sed 's/^/  /')"$'\n'
    fi
  done
fi
if [ "$units_found" -eq 1 ]; then
  echo '```'
  printf '%s' "$units_out"
  echo '```'
else
  echo "None on any node."
fi
echo

# --- audit ---------------------------------------------------------------
# Only when the cluster was deployed with auditing on; its absence is a
# configuration, not a problem.
LOG=/var/log/kubernetes/audit/audit.log
COLLECTED_AUDIT="artifacts/audit/${CLUSTER}/audit.log"
audit_cat() {
  if [ -s "$COLLECTED_AUDIT" ]; then cat "$COLLECTED_AUDIT"
  else podman exec "$NODE" cat "$LOG" 2>/dev/null; fi
}
if [ -s "$COLLECTED_AUDIT" ] || { [ "$OWN_CAP" -eq 1 ] && podman exec "$NODE" test -f "$LOG" 2>/dev/null; }; then
  echo "### API audit"
  echo
  echo '```'
  audit_cat | jq -s -r '
    "entries: \(length)",
    (group_by(.verb) | map("  \(.[0].verb): \(length)") | .[]),
    "",
    "by response:",
    (group_by(.responseStatus.code) | sort_by(-length)
     | map("  \(.[0].responseStatus.code // "-"): \(length)") | .[])'
  echo '```'
  echo

  # 403 is the shape worth naming: a component denied something it went on to
  # need, or one asking for what it should never have.
  denied=$(audit_cat | jq -s -r '
    [.[] | select(.responseStatus.code == 403)]
    | group_by(.user.username + .verb + (.objectRef.resource // "-"))
    | map("  \(length)x  \(.[0].user.username)  \(.[0].verb) \(.[0].objectRef.resource // "-")")
    | .[]')
  if [ -n "$denied" ]; then
    echo "Denied:"
    echo
    echo '```'
    printf '%s\n' "$denied"
    echo '```'
    echo
  fi
fi

echo "⚠ marks a component with less than $(( 2 * DETECTABLE_PERIOD ))s of running past its startup grace:"
echo "everything it logged is classified above, but a fault recurring slower than"
echo "~${DETECTABLE_PERIOD}s would not necessarily have appeared yet."
echo
echo "_Generated from the nodes' own filesystems; nothing here reached the API server._"
