#!/usr/bin/env bash
# Asserts that audit leaves no trace when KINC_AUDIT_RESOURCES is unset.
#
# Usage: ci-verify-audit-off.sh <cluster>
#
# Every CI job enables audit, so nothing else would catch a change that made it
# always-on. "Opt-in" is a claim about the unset case, and the unset case is the
# one no other test exercises.
set -euo pipefail

CLUSTER="$1"
NODE="kinc-${CLUSTER}-control-plane"

echo "=== Verifying audit is off when not asked for ==="

if podman exec "$NODE" test -e /etc/kubernetes/audit 2>/dev/null; then
  echo "❌ audit policy directory exists on a cluster that did not ask for audit"
  podman exec "$NODE" ls -la /etc/kubernetes/audit || true
  exit 1
fi
echo "✅ no audit policy directory"

if podman exec "$NODE" grep -q 'audit-policy-file' /etc/kubernetes/manifests/kube-apiserver.yaml 2>/dev/null; then
  echo "❌ kube-apiserver carries audit flags without being asked"
  podman exec "$NODE" grep 'audit' /etc/kubernetes/manifests/kube-apiserver.yaml || true
  exit 1
fi
echo "✅ kube-apiserver has no audit flags"

if podman exec "$NODE" test -s /var/log/kubernetes/audit/audit.log 2>/dev/null; then
  echo "❌ an audit log was written without being asked"
  exit 1
fi
echo "✅ no audit log written"

echo ""
echo "✅ Audit is inert unless KINC_AUDIT_RESOURCES names something"
