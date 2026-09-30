#!/usr/bin/env bash
# Asserts that no component is still logging at error level once it has settled.
#
# NOT RUN BY PR CI, on purpose. A cluster there exists for about 100 seconds -
# 61s to deploy, 42s of gates, then teardown - and antrea's agent, which starts
# only after the CNI is applied, is 40-70s old when the logs are captured. This
# judges whether something is *still* happening after its component came up,
# which needs the component to outlive the startup grace by about two of
# whatever period you want to detect. A 60s-period fault needs ~210s of
# component life. That is not available, and padding CI with sleeps to
# manufacture it is the test wagging the run.
#
# It is kept for two places where the record is long enough to conclude from:
# a local cluster that has been up for a while, and a scheduled soak. Run it
# against either, or against any archived capture:
#
#   ./tools/ci-verify-component-logs.sh                     # live cluster
#   KINC_LOG_CAPTURE=<dir> ./tools/ci-verify-component-logs.sh
#
# What PR CI keeps instead is the same analysis without the verdict: the state
# column in ci-summarize-run.sh says startup / once / stopped / ONGOING for
# every class on every run. A fault is described rather than enforced, which is
# honest about a record that cannot support the enforcement - and the fault
# that motivated this gate is asserted directly, and instantly, in
# ci-verify-crossnode.sh.
set -euo pipefail

# shellcheck source=tools/lib-component-logs.sh
. "$(dirname "$0")/lib-component-logs.sh"

# How long a component may be noisy while coming up, measured from its own
# first log line.
#
# 90s, from measurement rather than taste: on a healthy cluster every recurring
# class falls silent within 45s of its component's first line - kube-apiserver's
# controller.go bursts are the latest at 45s - so this is double the observed
# worst case. The two classes that appear later (63s and 87s) are single
# occurrences, which never fail a build anyway.
#
# Bigger is not safer. Grace is time in which a genuine fault is invisible, and
# at 120s a fault injected into a three-minute-old cluster went undetected
# because most of the component's life was still inside the window.
STARTUP="${1:-90}"

# A class is still going when its silence is shorter than three times its own
# widest gap. No constant in it, and that is the point: every fixed term tried
# here was wrong in the same way. A grace of 30s called a pair of simultaneous
# denials 28 seconds old "still recurring", because a widest gap of zero left a
# window made entirely of grace. A floor of 10s then called a four-occurrence
# burst with 1s gaps and 5s of silence ongoing - the same mistake one size
# down. Silence five times longer than the period is silence. Scaled to what
# the class actually does, there is nothing left to pick wrong.
# The slowest recurrence this gate claims to catch. Everything below follows
# from it, so the claim is stated once rather than implied by three constants.
#
# 60s is antrea's retry interval, the fault that motivated this gate. Slower
# ones exist - the kubelet's OOM retry was every 300s, cadvisor backs off to
# 20 minutes - and catching those would need components to live for tens of
# minutes, which a CI cluster does not. Those are reported as unjudgeable
# rather than quietly counted as clean.
DETECTABLE_PERIOD=60
# To see that something recurring is *still* recurring, a component has to
# outlive the grace by about two of its periods. Below this it is described,
# not judged.
JUDGEABLE=$(( STARTUP + 2 * DETECTABLE_PERIOD ))
# How long to let the cluster run before reading it, so that a fault recurring
# at DETECTABLE_PERIOD has had time to appear at all. Classification does not
# depend on it - every class in the record is judged whatever the age - but
# coverage does, and a component that has not run long enough is named.
SETTLE=$(( JUDGEABLE + 60 ))
# KINC_LOG_CAPTURE names a capture already on disk, taken before the cluster was
# torn down. Set, this reads that and touches nothing else; unset, it captures
# from the running cluster, which is what a local run wants.
#
# In CI it is always set, and the ordering is deliberate: collect, tear down,
# then parse. A record that is still being written is not one you can conclude
# from - "quiet" is measured against a clock that keeps moving while the log
# does not - and analysing a live cluster also means the analysis competes with
# whatever else is still running against it.
if [ -n "${KINC_LOG_CAPTURE:-}" ]; then
  CAP="$KINC_LOG_CAPTURE"
  OWN_CAP=0
else
  CAP="$(mktemp -d)"
  OWN_CAP=1
fi
VERDICT=0
# Without this, any command failing under `set -e` ends the run with a bare
# exit status and no output - which is how this gate first failed in CI, after
# a pod directory it had just listed held no log file yet. A gate that cannot
# say why it failed costs a whole cycle to diagnose.
trap 'rc=$?; if [ "$rc" -ne 0 ] && [ "$VERDICT" -eq 0 ]; then
        echo "❌ gate exited unexpectedly with status ${rc} - no verdict was reached"
      fi
      [ "$OWN_CAP" -eq 1 ] && rm -rf "$CAP"' EXIT

echo "=== Verifying no component still logs errors after its first ${STARTUP}s ==="

if [ "$OWN_CAP" -eq 1 ]; then
  NODES=$(kinc_nodes)
  if [ -z "$NODES" ]; then
    echo "❌ no kinc node containers are running - nothing to read"
    exit 1
  fi

  if ! age=$(kinc_cluster_age); then
    echo "❌ no node container reports a start time"
    exit 1
  fi
  if [ "$age" -lt "$SETTLE" ]; then
    echo "   cluster is ${age}s old, waiting $(( SETTLE - age ))s so a recurring fault can appear"
    sleep $(( SETTLE - age ))
  fi

  kinc_capture_pod_logs "$CAP"
  if [ "$KINC_UNREAD" -gt 0 ]; then
    echo "   ${KINC_UNREAD} pod director(ies) held no readable log at capture time"
  fi
else
  echo "   reading the capture at ${CAP}"
fi

if ! ls "${CAP}"/pod_* >/dev/null 2>&1; then
  echo "❌ captured no pod logs - nothing to read"
  exit 1
fi

# --- analyse -------------------------------------------------------------
# klog writes E and F at the start of its own field, after the capture's
# timestamp. The source site (file.go:line) is the class: it groups the same
# fault across occurrences without matching on a message body that carries pod
# names and IDs.
failed=0
late_singletons=""
thin=""
judged=0
# The end of the record, not the wall clock: see kinc_record_end. For a live
# capture the two are the same moment anyway.
if ! NOW=$(kinc_record_end "$CAP"); then
  echo "❌ the capture carries no readable timestamps"
  exit 1
fi

for f in "${CAP}"/*; do
  [ -s "$f" ] || continue
  # Kubernetes names never contain an underscore, so it separates the parts of
  # the capture's filename unambiguously and reads back as ns/pod.
  # The component's own first line: a pod that started late is judged from when
  # it started, not from when the cluster did.
  t0_epoch="$(kinc_first_seen "$f")" || continue

  # Every class this component logged is classified, whatever its age. A class
  # that last fired twenty seconds in and has been silent for three minutes has
  # stopped, and the record says so regardless of how young the component is -
  # refusing to look at it discards a conclusive answer.
  #
  # Age limits one thing only: whether a fault that has *not* appeared yet has
  # had time to. That is a statement about coverage, recorded below, not a
  # reason to skip what is in front of us.
  window=$(( (NOW - t0_epoch) - STARTUP ))
  if [ "$window" -gt 0 ]; then
    judged=$(( judged + 1 ))
  fi
  if [ "$window" -lt $(( 2 * DETECTABLE_PERIOD )) ]; then
    thin="${thin}$(kinc_label "$(basename "$f")") (${window}s past startup)"$'\n'
  fi

  label="$(kinc_label "$(basename "$f")")"

  # One line per error: its timestamp and its class.
  kinc_class_lines "$f" > "${CAP}.errors"

  [ -s "${CAP}.errors" ] || continue

  while read -r cls; do
    [ -z "$cls" ] && continue

    # Occurrences of this class, as epoch seconds, in order.
    awk -F'\t' -v c="$cls" '$2==c { print $1 }' "${CAP}.errors" \
      | while read -r ts; do date -d "$ts" +%s; done | sort -n -u > "${CAP}.times"

    count=$(wc -l < "${CAP}.times")
    last=$(tail -1 "${CAP}.times")
    quiet=$(( NOW - last ))
    into_life=$(( last - t0_epoch ))

    # Said nothing since this component finished coming up.
    [ "$into_life" -le "$STARTUP" ] && continue

    if [ "$count" -le 1 ]; then
      late_singletons="${late_singletons}${label}: ${cls} (once, at +${into_life}s)"$'\n'
      continue
    fi

    maxgap=$(awk 'NR>1 { print $1 - prev } { prev = $1 }' "${CAP}.times" \
             | sort -n | awk '{ g[NR] = $1 } END { print (NR ? g[int((NR+1)/2)] : 0) }')
    window=$(( 3 * maxgap ))

    [ "$quiet" -gt "$window" ] && continue

    if [ "$failed" -eq 0 ]; then echo ""; fi
    failed=1
    echo "❌ ${label}"
    echo "     ${cls}  x${count}, every ${maxgap}s at widest, still going at +${into_life}s (${quiet}s ago)"
  done < <(cut -f2 "${CAP}.errors" | sort -u)
done

if [ -n "$thin" ]; then
  echo ""
  echo "   thin coverage - everything these logged was classified, but they have"
  echo "   not run long enough past startup for a fault recurring slower than"
  echo "   ~${DETECTABLE_PERIOD}s to have shown up yet:"
  printf '%s' "$thin" | sed 's/^/     /'
fi

if [ -n "$late_singletons" ]; then
  echo ""
  echo "   logged once after settling, not treated as a failure:"
  printf '%s' "$late_singletons" | sed 's/^/     /'
fi

# A run in which nothing could be judged is not a pass.
#
# If every component was captured before it outlived the startup grace, every
# class it logged is inside that grace, nothing is eligible to fail, and success
# means only that the gate could not reach a verdict. That is how this went
# inert without anyone noticing: parsing moved after teardown, the settle wait
# stayed on the path CI no longer took, components were captured at 60-86s old
# against a 90s grace, and all 76 classes across three jobs came back "startup"
# on a green run.
#
# So the absence of a verdict is itself a failure, and it names the knob.
if [ "$judged" -eq 0 ]; then
  echo ""
  echo "❌ no component outlived the ${STARTUP}s startup grace, so nothing could be"
  echo "   judged - this run proves nothing. Let the cluster run longer before"
  echo "   capturing (KINC_CAPTURE_AGE in ci-collect-diagnostics.sh)."
  VERDICT=1
  exit 1
fi

VERDICT=1
if [ "$failed" -ne 0 ]; then
  echo ""
  echo "❌ a component is still logging errors after its first ${STARTUP}s"
  exit 1
fi

echo "✅ every component fell silent within ${STARTUP}s of starting"
