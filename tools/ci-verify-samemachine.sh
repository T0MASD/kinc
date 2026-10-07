#!/usr/bin/env bash
# Asserts that two node containers on the SAME machine carry pod traffic over
# the tunnel rather than delivering it locally.
#
# ci-verify-crossnode.sh proves the cross-machine path. This is the case it
# never reaches, and the one that fails if peering is hub-and-spoke: a node's
# identity is its tunnel address, so two nodes sharing a machine still have to
# reach each other through wg0, and WireGuard does not relay between peers.
#
# Usage: ci-verify-samemachine.sh <node-a> <node-b>
set -uo pipefail

[ $# -eq 2 ] || { echo "usage: $0 <node-a> <node-b>"; exit 1; }
NODE_A="$1"; NODE_B="$2"
NS=kinc-samemachine
fail=0

kubectl create namespace "$NS" >/dev/null 2>&1 || true
kubectl -n "$NS" delete pod sm-server sm-client --force --grace-period=0 >/dev/null 2>&1

cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: sm-server, namespace: ${NS}, labels: {app: sm-server}}
spec:
  nodeName: ${NODE_A}
  tolerations: [{operator: Exists}]
  containers: [{name: agnhost, image: registry.k8s.io/e2e-test-images/agnhost:2.47,
                command: ["/agnhost","netexec","--http-port=8080"]}]
---
apiVersion: v1
kind: Pod
metadata: {name: sm-client, namespace: ${NS}}
spec:
  nodeName: ${NODE_B}
  tolerations: [{operator: Exists}]
  containers: [{name: agnhost, image: registry.k8s.io/e2e-test-images/agnhost:2.47,
                command: ["sleep","3600"]}]
YAML

for _ in $(seq 1 40); do
  [ "$(kubectl -n "$NS" get pod sm-server sm-client --no-headers 2>/dev/null | awk '$3=="Running"' | wc -l)" = 2 ] && break
  sleep 10
done

# Assert the placement rather than trusting it: both pods on one node makes
# every check below pass without the datapath under test being used.
a=$(kubectl -n "$NS" get pod sm-server -o jsonpath='{.spec.nodeName}' 2>/dev/null)
b=$(kubectl -n "$NS" get pod sm-client -o jsonpath='{.spec.nodeName}' 2>/dev/null)
if [ "$a" != "$NODE_A" ] || [ "$b" != "$NODE_B" ] || [ "$a" = "$b" ]; then
  echo "❌ placement wrong: server on '${a}', client on '${b}'"; exit 1
fi
echo "✅ sm-server on ${a}, sm-client on ${b}"

SIP=$(kubectl -n "$NS" get pod sm-server -o jsonpath='{.status.podIP}' 2>/dev/null)
[ -n "$SIP" ] || { echo "❌ sm-server has no pod IP"; exit 1; }

# The body is checked, not the exit status: a TCP connection proves nothing
# about which pod answered.
if ! raw=$(kubectl -n "$NS" exec sm-client -- \
           sh -c "wget -qO- --timeout=15 http://${SIP}:8080/hostname" 2>&1); then
  echo "❌ request could not be made: ${raw}"; exit 1
fi
got=$(printf '%s' "$raw" | tr -d '[:space:]')
if [ "$got" != "sm-server" ]; then
  echo "❌ returned '${got}' (wanted 'sm-server')"; fail=1
else
  echo "✅ ${NODE_B} reached ${NODE_A} across the tunnel"
fi

# Traceflow is the only check that shows the datapath. Without a tunnelDst the
# packet never left the sender's node, and the two are not separate on the
# overlay even though they are separate Nodes to Kubernetes.
kubectl delete traceflow sm-trace >/dev/null 2>&1
cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: crd.antrea.io/v1beta1
kind: Traceflow
metadata: {name: sm-trace}
spec:
  source: {namespace: ${NS}, pod: sm-client}
  destination: {namespace: ${NS}, pod: sm-server}
  packet: {ipHeader: {protocol: 6}, transportHeader: {tcp: {dstPort: 8080}}}
YAML
for _ in $(seq 1 15); do
  [ "$(kubectl get traceflow sm-trace -o jsonpath='{.status.phase}' 2>/dev/null)" = "Succeeded" ] && break
  sleep 2
done
tun=$(kubectl get traceflow sm-trace -o json 2>/dev/null \
      | jq -r '[.status.results[]?.observations[]?.tunnelDstIP] | map(select(.)) | .[0] // ""')
if [ -n "$tun" ]; then
  echo "✅ same-machine traffic is encapsulated to ${tun}"
else
  echo "❌ no tunnelDst: the packet did not take the overlay"
  kubectl get traceflow sm-trace -o json 2>/dev/null | jq -r '.status' | head -20
  fail=1
fi
kubectl delete traceflow sm-trace >/dev/null 2>&1

echo
[ $fail = 0 ] && echo "✅ Nodes sharing a machine still tunnel to each other" \
              || echo "❌ Same-machine tunnelling is broken"
exit $fail
