#!/usr/bin/env bash
# The analysis phase: every check that reads the capture, run after teardown.
#
#   ./tools/ci-analyse-capture.sh <cluster> [<cluster>...]
#
# A CI run has three phases, and which one a check belongs to is decided by
# what it needs to look at:
#
#   1. live    - gates that need a running cluster (init, crossnode, faro,
#                node resources, restart). They run while it is up because
#                they cannot run any other way.
#   2. capture - ci-collect-diagnostics.sh, -faro.sh, -audit.sh write the
#                record, then cleanup.sh tears the cluster down.
#   3. analyse - this. Everything that reads the record.
#
# The split is not tidiness. A question like "has this stopped?" cannot be
# answered against a live cluster: silence is measured against a clock that
# keeps moving while the log does not, so the newest occurrence is always
# seconds old and nothing ever looks settled. It needs a record that has
# stopped being written. Both ci-verify-component-logs.sh and
# ci-verify-denials.sh were failed by asking too early, at two thresholds each,
# before they moved here.
#
# The other reason is reach. A component's own log never arrives on the
# runner's console - it exists in the capture and nowhere else - so a check
# that greps the workflow log sees none of it and passes every time. That is
# how a deprecation printed on every node of every run stayed invisible until
# somebody read an artifact by hand.
#
# Running them from one place rather than as four workflow steps buys two
# things. Every check runs even when an earlier one fails - as separate steps
# under `bash -e`, a failure against the first cluster meant the second was
# never looked at - and a job cannot acquire a capture-reading check in one
# place and not another, which is how component logs went unexamined on pull
# requests while running in the release.
set -euo pipefail

cd "$(dirname "$0")/.."

CLUSTERS=("$@")
if [ "${#CLUSTERS[@]}" -eq 0 ]; then
  echo "usage: $0 <cluster> [<cluster>...]"
  exit 1
fi

ART="${KINC_ARTIFACTS:-artifacts}"
mkdir -p "${ART}/summary"
failed=()
passed=()

# Runs one check to completion whatever it returns, records the verdict, and
# keeps going. Output is kept inline so a failure is read where it happened.
run_check() {
  local name="$1"; shift
  echo ""
  echo "──────────────────────────────────────────────────────────────────────"
  echo "  ${name}"
  echo "──────────────────────────────────────────────────────────────────────"
  if "$@"; then
    passed+=("$name")
  else
    failed+=("$name")
  fi
}

for cluster in "${CLUSTERS[@]}"; do
  cap="${ART}/diagnostics/${cluster}/componentlogs"
  run_check "component logs settled [${cluster}]" \
    env KINC_LOG_CAPTURE="$cap" ./tools/ci-verify-component-logs.sh
  run_check "no deprecations logged [${cluster}]" \
    env KINC_LOG_CAPTURE="$cap" \
        KINC_DEPRECATION_REPORT="${ART}/summary/deprecations-${cluster}.txt" \
        ./tools/ci-verify-deprecations.sh
done

# Takes every cluster at once rather than one at a time.
run_check "no denials persisted" ./tools/ci-verify-denials.sh "${CLUSTERS[@]}"

# Describes rather than judges, so its verdict is not collected - but it is
# part of the phase, and a job that skipped it uploaded an empty summary.
mkdir -p "${ART}/summary"
for cluster in "${CLUSTERS[@]}"; do
  echo ""
  echo "──────────────────────────────────────────────────────────────────────"
  echo "  run summary [${cluster}]"
  echo "──────────────────────────────────────────────────────────────────────"
  KINC_LOG_CAPTURE="${ART}/diagnostics/${cluster}/componentlogs" \
    ./tools/ci-summarize-run.sh "$cluster" \
    | tee "${ART}/summary/${cluster}.md" \
    | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}" || true
done

echo ""
echo "══════════════════════════════════════════════════════════════════════"
echo "  Analysis phase: ${#passed[@]} passed, ${#failed[@]} failed"
echo "══════════════════════════════════════════════════════════════════════"
for n in "${passed[@]}"; do echo "  ✅ ${n}"; done
for n in "${failed[@]}"; do echo "  ❌ ${n}"; done

[ "${#failed[@]}" -eq 0 ] || exit 1
