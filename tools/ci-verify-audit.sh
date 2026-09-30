#!/usr/bin/env bash
# Asserts that API-server audit logging recorded a read.
#
# Usage: ci-verify-audit.sh <cluster> <group/resource> [more]
#
# Flags being present proves nothing: a policy that matches no resource writes
# an empty log and looks identical to a working one. So this reads each audited
# resource and then requires a matching entry to appear.
set -euo pipefail

CLUSTER="$1"; shift
NODE="kinc-${CLUSTER}-control-plane"
LOG=/var/log/kubernetes/audit/audit.log

echo "=== Verifying API-server audit ==="

if ! podman exec "$NODE" test -f /etc/kubernetes/audit/policy.yaml; then
  echo "❌ no audit policy on ${NODE}"
  exit 1
fi
echo "✅ audit policy present"

# The flags must have reached the running API server, not just the config.
if ! podman exec "$NODE" grep -q 'audit-policy-file' /etc/kubernetes/manifests/kube-apiserver.yaml; then
  echo "❌ kube-apiserver static pod carries no audit flags"
  exit 1
fi
echo "✅ kube-apiserver started with audit flags"

for entry in "$@"; do
  group="${entry%%/*}"
  resource="${entry#*/}"

  # Read it, so there is something to record. If the read itself fails there is
  # nothing to find, and the wait below would blame the audit policy for it.
  if ! kubectl get "$resource" -A >/dev/null 2>&1 && ! kubectl get "$resource" >/dev/null 2>&1; then
    echo "❌ cannot read '${resource}' to generate an audit entry"
    kubectl get "$resource" -A 2>&1 | head -3
    exit 1
  fi

  found=false
  for _ in $(seq 1 30); do
    # Match on the objectRef, decoded as JSON - not a grep for the word, which
    # would also match the policy path or an unrelated field.
    if podman exec "$NODE" sh -c "test -f $LOG" 2>/dev/null; then
      if podman exec "$NODE" cat "$LOG" 2>/dev/null \
         | jq -e --arg r "$resource" --arg g "$group" \
             'select(.objectRef.resource == $r and (.objectRef.apiGroup // "") == $g)
              | select(.verb == "get" or .verb == "list" or .verb == "watch")' >/dev/null 2>&1; then
        found=true
        break
      fi
    fi
    sleep 2
  done

  if [ "$found" != true ]; then
    echo "❌ no audit entry for '${entry}' after reading it"
    podman exec "$NODE" sh -c "tail -3 $LOG" 2>/dev/null || echo "   (audit log absent or empty)"
    exit 1
  fi
  echo "✅ '${entry}' recorded in the audit log"
done

# A delete must be recorded, and with the identity behind it.
#
# The reads above pass whether or not the policy names "delete": a verb list
# that dropped it writes the same get/list/watch entries, and every removal
# would go unattributed while the log still looked healthy. So this removes a
# real object and requires its own entry back, by name.
#
# ConfigMaps are the probe because they are cheap, namespaced and audited on
# every caller below. If the caller did not ask for them, the probe cannot run
# and that is an error in the call, not something to skip quietly.
case " $* " in
  *" /configmaps "*) ;;
  *)
    echo "❌ ci-verify-audit.sh needs /configmaps among its resources to probe deletes"
    exit 1
    ;;
esac

probe="audit-delete-probe-$$"
if ! kubectl -n default create configmap "$probe" --from-literal=probe=1 >/dev/null 2>&1; then
  echo "❌ cannot create a ConfigMap, so no delete can be generated to look for"
  kubectl -n default create configmap "$probe" --from-literal=probe=1 2>&1 | head -3
  exit 1
fi
if ! kubectl -n default delete configmap "$probe" >/dev/null 2>&1; then
  echo "❌ cannot delete the probe ConfigMap"
  kubectl -n default delete configmap "$probe" 2>&1 | head -3
  exit 1
fi

found=false
for _ in $(seq 1 30); do
  if podman exec "$NODE" cat "$LOG" 2>/dev/null \
     | jq -e --arg n "$probe" '
         select(.verb == "delete"
                and .objectRef.resource == "configmaps"
                and .objectRef.name == $n)
         | select((.user.username // "") != "")' >/dev/null 2>&1; then
    found=true
    break
  fi
  sleep 2
done

if [ "$found" != true ]; then
  echo "❌ deleting '${probe}' left no audit entry - the policy is recording reads only"
  podman exec "$NODE" sh -c "grep -c '\"verb\":\"delete\"' $LOG" 2>/dev/null \
    | sed 's/^/   delete entries in the whole log: /'
  exit 1
fi
echo "✅ deletes are recorded, attributed to the caller that made them"

# A resource that is not in the policy must not be recorded, or the policy is
# not narrowing anything and the volume claim is false.
#
# The read has to succeed for the absence below to mean anything: if it fails,
# nothing was read, nothing is recorded, and the check passes having tested
# nothing.
if ! kubectl get secrets -A >/dev/null 2>&1; then
  echo "❌ cannot read secrets, so their absence from the log proves nothing"
  exit 1
fi
if podman exec "$NODE" cat "$LOG" 2>/dev/null \
   | jq -e 'select(.objectRef.resource == "secrets")' >/dev/null 2>&1; then
  echo "❌ 'secrets' was recorded but is not in the policy"
  exit 1
fi
echo "✅ unlisted resources are not recorded"

echo ""
echo "✅ Audit logging records the resources it was asked to"
