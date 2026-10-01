#!/usr/bin/env bash
# Fail if any component logged a deprecation while the cluster ran.
#
# This is the runtime half of the deprecation gate. ci-verify-no-deprecated-apis.sh
# is the static half: it reads our sources and catches a deprecated API we ask
# for. It cannot see what a component says about how we configured it, which is
# where the other kind lives:
#
#   kubelet: Flag --feature-gates has been deprecated, This parameter should be
#   set via the config file specified by the Kubelet's --config flag
#
# That printed on every node of every run for as long as the flag existed, and
# no gate could see it, because of where it printed.
#
# It reads the capture, never the workflow log and never a live cluster:
#
#   - The workflow log holds only what a step wrote to stdout. A component's
#     own log reaches the runner's console at no point whatsoever; it exists in
#     the capture and nowhere else. Grepping the workflow log therefore comes
#     back empty on a run with a hundred deprecations in it, and reads exactly
#     like a clean one.
#   - A live `gh run watch` is worse: it scrolls, and leaves nothing to grep.
#
# So this runs in the analysis phase, after the cluster is torn down, against
# the same capture every other post-teardown gate reads.
#
# It always writes its findings to deprecations.txt beside the capture, pass or
# fail, so the artifact carries the evidence for the verdict rather than just
# the verdict.
set -euo pipefail

CAP="${KINC_LOG_CAPTURE:-}"
if [ -z "$CAP" ]; then
  echo "❌ KINC_LOG_CAPTURE is unset - this gate reads a capture, not a cluster"
  exit 1
fi
if [ ! -d "$CAP" ]; then
  echo "❌ no capture at ${CAP}"
  exit 1
fi

# What a deprecation looks like in a log line. Deliberately broad: a missed
# deprecation is the failure this gate exists to prevent, and a false positive
# costs one allowlist entry.
PATTERNS='deprecat|will be removed in|no longer supported|removed in a future release'

# Lines that match the patterns but are not a component warning us about
# anything. Each entry is an extended regex and the reason it is not a finding.
# Add to this only for something that is genuinely not ours to fix - the
# kubelet flag below was in this shape and was fixable, so it was fixed.
ALLOW=$(cat <<'EOF'
"v2-deprecation"	etcd echoes its whole config at startup, and that is a field name in it, not a warning
EOF
)

# A capture with nothing in it must not read as a clean run. This is the same
# failure the gate is built against, one level up: an empty grep over an empty
# directory is indistinguishable from an empty grep over a healthy cluster.
files=$(find "$CAP" -type f | wc -l)
if [ "$files" -eq 0 ]; then
  echo "❌ the capture at ${CAP} holds no files - this run proves nothing"
  exit 1
fi

# Where the findings land. The caller chooses, because the obvious place -
# beside the capture - is wrong: diagnostics are uploaded before teardown, and
# this runs after it, so a report written there is produced after the only step
# that would have uploaded it and reaches no artifact at all. The analysis
# phase points this at the summary directory, which is uploaded after it runs.
REPORT="${KINC_DEPRECATION_REPORT:-$(dirname "$CAP")/deprecations.txt}"
mkdir -p "$(dirname "$REPORT")"

# -a forces text: a captured log can carry NUL bytes from a partial write, and
# grep would otherwise decline to print matches from it.
#
# No -o, and no context wrapper around the alternation. An earlier hand-run of
# this check used `grep -oE '[^|]{0,120}(deprecat|...)[^|]{0,120}'` to get
# surrounding context, and it reported zero matches over a capture holding a
# hundred of them - the bounded repetitions do not behave as intended against
# these very long lines. Whole lines, no cleverness.
hits=$(grep -rahniE "$PATTERNS" "$CAP" 2>/dev/null || true)

found=0
: > "$REPORT"
while IFS= read -r line; do
  [ -n "$line" ] || continue
  allowed=0
  while IFS=$'\t' read -r pattern reason; do
    [ -n "$pattern" ] || continue
    if printf '%s' "$line" | grep -qE "$pattern"; then
      allowed=1
      printf 'ALLOWED (%s)\n  %s\n' "$reason" "$line" >> "$REPORT"
      break
    fi
  done <<< "$ALLOW"
  [ "$allowed" -eq 1 ] && continue
  printf 'FOUND\n  %s\n' "$line" >> "$REPORT"
  found=$((found + 1))
done <<< "$hits"

echo "=== Verifying no component logged a deprecation (${files} captured files) ==="
echo "   findings written to ${REPORT}"

if [ "$found" -gt 0 ]; then
  echo ""
  # Group by the deprecation itself rather than per occurrence: the same flag
  # on every node is one thing to fix, not one per node.
  # Strip what differs between occurrences - the capture's line number and
  # timestamp, then the host and the pid-bearing process tag - so the same
  # deprecation on three nodes groups into one line with a count, which is what
  # it is: one thing to fix.
  grep -A1 '^FOUND' "$REPORT" | grep -v '^FOUND' | grep -v '^--' \
    | sed -E 's/^[[:space:]]*[0-9]+:[0-9TZ:+.-]+ //' \
    | sed -E 's/^[^ ]+ [^ ]+\[[0-9]+\]: //' \
    | cut -c1-110 | sort | uniq -c | sort -rn \
    | sed 's/^/   /'
  echo ""
  echo "❌ ${found} deprecation line(s) in the capture"
  echo "   Fix it, or - only if it is genuinely not ours - add it to ALLOW with a reason."
  exit 1
fi

echo "✅ no component logged a deprecation"
