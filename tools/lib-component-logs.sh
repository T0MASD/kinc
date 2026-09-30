#!/usr/bin/env bash
# Shared capture and classification of component logs, used by the gate that
# judges them (ci-verify-component-logs.sh) and the summary that describes them
# (ci-summarize-run.sh).
#
# One implementation on purpose. The two answer different questions - pass/fail
# versus "here is what happened" - but they must answer them about the same
# bytes, classified the same way. Two copies of this drifted once already in
# this repo, in the CI workflow, and the copy that mattered was the one nobody
# had updated.
#
# Sourced, not executed. It defines functions and sets no shell options, so the
# caller's `set -euo pipefail` stays in force.

# Timestamps are compared as strings, which is only valid while they are the
# same ISO-8601 shape. They are not: the CRI writes pod logs with a "+00:00"
# offset because CRI-O formats time.Now() in time.Local, and Go emits "Z" only
# for the time.UTC location itself - the node is UTC and it makes no difference,
# nor does any CRI-O setting, since it is a property of the call. kinc's own
# logs use "Z". Same instant, and "+" sorts below "Z", so a mixed capture would
# order every pod line before every kinc line regardless of when they happened.
#
# So the offset is folded to Z before any comparison. Sub-second digits differ
# too - seconds, microseconds, nanoseconds - but those compare correctly as
# strings once the suffix matches, because the fraction is left-aligned.
kinc_iso() { sed -E 's/\+00:00$/Z/; s/\+00:00([^0-9])/Z\1/g'; }

# Every kinc node container, one per line, or just one cluster's when named.
# Empty output means none are running, which every caller must treat as an error
# rather than an empty result.
#
# The filter matters with more than one cluster up: unfiltered, a per-cluster
# report silently describes every cluster on the host, and two summaries come
# back identical and twice the size they should be.
kinc_nodes() {
  local cluster="${1:-}"
  if [ -n "$cluster" ]; then
    podman ps --format '{{.Names}}' | grep "^kinc-${cluster}-" || true
  else
    podman ps --format '{{.Names}}' | grep '^kinc-' || true
  fi
}

# Seconds since the earliest-started node container, i.e. the cluster's age.
#
# Read through jq rather than --format: podman's Go template prints a time with
# a trailing zone name ("+0300 EEST") that date(1) refuses, while the JSON field
# is RFC 3339, which both date(1) and a string comparison understand.
kinc_cluster_age() {
  local oldest="" started n
  for n in $(kinc_nodes); do
    started=$(podman inspect "$n" 2>/dev/null | jq -r '.[0].State.StartedAt')
    [ -z "$started" ] && continue
    if [ -z "$oldest" ] || [[ "$started" < "$oldest" ]]; then oldest="$started"; fi
  done
  [ -z "$oldest" ] && return 1
  echo $(( $(date +%s) - $(date -d "$oldest" +%s) ))
}

# Capture every pod log into <dir>/pod_<ns>_<pod>, and set KINC_UNREAD to the
# number of pod directories that could not be read.
#
# Read off the nodes' own filesystems, never through the API. `kubectl logs` and
# `kubectl exec` reach the kubelet on :10250, and every one of those connections
# makes the kubelet log at E level when it closes - so reading logs over the API
# writes into the logs being read. The gate failed a build on its own footprint
# that way. Reading files also works when the API server is what is broken,
# which is when logs matter most.
#
# The CRI writes /var/log/pods/<ns>_<pod>_<uid>/<container>/N.log, each line
# beginning with an RFC 3339 timestamp.
kinc_capture_pod_logs() {
  local dir="$1" cluster="${2:-}" n pods d ns rest pod
  KINC_UNREAD=0
  for n in $(kinc_nodes "$cluster"); do
    pods=$(podman exec "$n" sh -c 'ls /var/log/pods 2>/dev/null') || pods=""
    for d in $pods; do
      ns="${d%%_*}"
      rest="${d#*_}"
      pod="${rest%_*}"
      case "$ns" in kube-system|local-path-storage|kinc-validation) ;; *) continue ;; esac
      # A pod directory can hold no log file yet, or be garbage-collected by the
      # kubelet between being listed and being read. Both are normal and an
      # empty capture is the right answer - but count them, because a large
      # number means the capture is not representative.
      if ! podman exec "$n" sh -c "cat /var/log/pods/${d}/*/*.log" \
           >> "${dir}/pod_${ns}_${pod}" 2>/dev/null; then
        KINC_UNREAD=$(( KINC_UNREAD + 1 ))
      fi
    done
  done
  kinc_mark_capture_end "$dir"
}

# When observation ended, recorded while it is known.
#
# Everything afterwards measures "how long has this been quiet" against this.
# After teardown there is no way to recover it, and the newest surviving log
# line is not it: if every component fell silent a minute before capture, that
# minute is real quiet and inferring the end from the log would throw it away.
#
# Written after a capture finishes, not before it starts. Before, it names a
# moment earlier than lines the same capture goes on to read, and a class whose
# last occurrence is after the record supposedly ended gets a negative quiet
# time - which compares less than every threshold and reads as ONGOING. Every
# capture function calls this last, so the marker is whichever finished most
# recently.
kinc_mark_capture_end() { date +%s > "${1}/.captured-at"; }

# Every W, E and F line in <file> as "<timestamp>\t<source site>\t<severity>".
#
# klog writes the severity letter at the start of its own field, after the
# capture's timestamp. The source site (file.go:line) is the class: it groups the same
# fault across occurrences without matching on a message body that carries pod
# names, UIDs and addresses.
#
# W is included and reported separately, so callers choose. The gate judges E
# and F only: a warning is a component saying something it expected to be able
# to say, and failing a build on one would fail it on "Skipping API
# apiextensions.k8s.io/v1beta1 because it has no resources", which every
# apiserver logs on every start. The summary shows warnings, because leaving
# them out is how "v1 Endpoints is deprecated" printed on every run in this
# repo without anyone reading it. Interval expressions are spelled out because mawk,
# which is awk on some runners, has not always supported them.
kinc_class_lines() {
  awk '
    /[WEF][0-9][0-9][0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]\./ {
      if (match($0, /[A-Za-z_0-9]+\.go:[0-9]+\]/)) {
        site = substr($0, RSTART, RLENGTH - 1)
        if (match($0, /[WEF][0-9][0-9][0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]\./)) {
          print $1 "\t" site "\t" substr($0, RSTART, 1)
        }
      }
    }' "$1"
}

# The component's first log line as epoch seconds: when it started, as far as
# its own record is concerned. A pod that started late is judged from when it
# started, not from when the cluster did.
kinc_first_seen() {
  local t0
  # The smallest timestamp, not the first line. A pod's containers are captured
  # one after another, so the file is not in time order and its first line can
  # be minutes later than another container's earliest - which showed up as a
  # class that began before the component did.
  #
  # Done inside awk rather than `sort | head -1`, which SIGPIPEs sort under
  # `set -o pipefail` and turns a healthy read into a failure.
  t0="$(kinc_iso < "$1" | awk 'NF { if (min == "" || $1 < min) min = $1 } END { print min }')"
  [ -z "$t0" ] && return 1
  date -d "$t0" +%s 2>/dev/null
}

# "pod_kube-system_antrea-agent-x" -> "kube-system/antrea-agent-x".
# Kubernetes names never contain an underscore, so it separates the parts of a
# capture's filename unambiguously.
kinc_label() {
  local base="$1" label
  case "$base" in
    pod_*)  label="${base#pod_}"; echo "${label/_//}" ;;
    node_*) echo "node ${base#node_}" ;;
    *)      echo "$base" ;;
  esac
}

# The last moment the capture describes, as epoch seconds.
#
# Analysis measures how long a class has been quiet, and that has to be against
# the end of the record - not against the wall clock. Once a capture is read
# from disk after the cluster is gone, "now" keeps advancing while the record
# does not, so every class drifts toward looking stopped, and the same artifact
# gives a different answer tomorrow than today.
#
# Against the record's own end it is reproducible: re-parsing a downloaded
# artifact months later returns exactly what the run returned.
kinc_record_end() {
  local dir="$1"
  # Recorded at capture time where available; otherwise the newest line in the
  # capture, which is a floor on it.
  if [ -s "${dir}/.captured-at" ]; then
    cat "${dir}/.captured-at"
    return 0
  fi
  { for f in "$dir"/*; do
      [ -s "$f" ] || continue
      kinc_iso < "$f" | awk 'NF { if ($1 > max) max = $1 } END { if (max != "") print max }' 
    done; } | sort | awk 'END { print }' | {
      read -r t || return 1
      [ -z "$t" ] && return 1
      date -d "$t" +%s 2>/dev/null
    }
}
