#!/usr/bin/env bash
# Asserts that a kinc cluster is genuinely multi-node and that pod traffic
# crosses between its nodes through Antrea's geneve tunnel.
#
# Usage: ci-verify-crossnode.sh <control-plane-node> <worker-node> [more workers]
#
# Every check here exists because the one before it passes without it:
# a node can register and never become Ready; two pods can be Ready and both
# sit on one node, where nothing tunnels; traffic can flow while the traceflow
# that was supposed to prove it never left the sender.
set -euo pipefail

CP_NODE="$1"; shift
WORKERS=("$@")
NS=kinc-validation

echo "=== Verifying the cluster is multi-node ==="

# By name, never --all: 'wait --all' is satisfied by whatever is present, so a
# worker that never joined leaves a cluster-wide check green.
for node in "$CP_NODE" "${WORKERS[@]}"; do
  kubectl wait --for=condition=Ready "node/${node}" --timeout=300s >/dev/null
  echo "✅ ${node} Ready"
done

# The role the spec asked for, applied after registration because
# NodeRestriction refuses a kubernetes.io label a kubelet sets for itself.
for node in "${WORKERS[@]}"; do
  if ! kubectl get node "$node" -o json \
       | jq -e '.metadata.labels["node-role.kubernetes.io/worker"] != null' >/dev/null; then
    echo "❌ ${node} carries no worker role label"
    kubectl get node "$node" -o json | jq -r '.metadata.labels | to_entries[] | "   \(.key)=\(.value)"'
    exit 1
  fi
  echo "✅ ${node} carries its worker role"
done

echo ""
echo "=== Verifying pod traffic crosses nodes ==="

kubectl -n "$NS" wait --for=condition=Ready pod/xnode-server pod/xnode-client --timeout=300s >/dev/null

# Assert the placement rather than trusting the nodeSelector that asked for it.
# Both pods on one node makes every check below pass over a datapath that never
# tunnelled, which is the failure this whole gate exists to catch.
server_node=$(kubectl -n "$NS" get pod xnode-server -o jsonpath='{.spec.nodeName}')
client_node=$(kubectl -n "$NS" get pod xnode-client -o jsonpath='{.spec.nodeName}')
if [ "$server_node" = "$client_node" ]; then
  echo "❌ both probes landed on '${server_node}'; nothing would cross a tunnel"
  exit 1
fi
echo "✅ xnode-server on ${server_node}, xnode-client on ${client_node}"

# Real traffic, by Service name: CoreDNS, kube-proxy and the datapath together.
# The body is checked, not just the exit status - 'agnhost connect' proves the
# TCP connection and nothing about which pod answered, and on one node that is
# the same result as on two.
# The exec's own status is kept, so a failed request is reported as a failed
# request rather than as an empty body.
if ! raw=$(kubectl -n "$NS" exec xnode-client -- \
           sh -c 'wget -qO- --timeout=15 http://xnode-service:8080/hostname' 2>&1); then
  echo "❌ cross-node request could not be made: ${raw}"
  kubectl -n "$NS" get endpoints xnode-service -o json | jq -r '.subsets // "no endpoints"'
  exit 1
fi
got=$(printf '%s' "$raw" | tr -d '[:space:]')
if [ "$got" != "xnode-server" ]; then
  echo "❌ cross-node Service request returned '${got}' (wanted 'xnode-server')"
  kubectl -n "$NS" get endpoints xnode-service -o json | jq -r '.subsets // "no endpoints"'
  exit 1
fi
echo "✅ client on ${client_node} reached the Service on ${server_node}"

# Traceflow reports what the datapath did with a packet, per node. This is the
# only check that shows the tunnel itself.
AGENT=$(kubectl -n kube-system get pod -l app=antrea,component=antrea-agent \
        --field-selector "spec.nodeName=${client_node}" -o name | head -1)
if [ -z "$AGENT" ]; then
  echo "❌ no antrea-agent on ${client_node}"
  exit 1
fi

tf=$(kubectl -n kube-system exec "$AGENT" -c antrea-agent -- \
     antctl traceflow -S "${NS}/xnode-client" -D "${NS}/xnode-server" \
     -f tcp,tcp_dst=8080 -o json 2>/dev/null)

report() {
  printf '%s' "$tf" | jq -r '"   phase=\(.phase)",
    (.results[]? | "   node \(.node):",
      (.observations[]? | "      \(.component)\(if .componentInfo then "/"+.componentInfo else "" end) -> \(.action)\(if .tunnelDstIP then " tunnelDst="+.tunnelDstIP else "" end)"))' || true
}

# Succeeded, observed on both nodes, encapsulated by the sender and received by
# the far side. A traceflow that only ever reports the sending node describes a
# packet that never left it.
if ! printf '%s' "$tf" | jq -e '
      .phase == "Succeeded"
      and ([.results[].node] | unique | length) == 2
      and ([.results[].observations[] | select(.tunnelDstIP != null)] | length) > 0
      and ([.results[].observations[].action] | index("Received") != null)
      and ([.results[].observations[].action] | index("Delivered") != null)
     ' >/dev/null; then
  echo "❌ traffic did not traverse a tunnel between two nodes"
  report
  exit 1
fi
echo "✅ traceflow crossed the tunnel:"
report

# Every agent can reach the tool it programs the host's rules with.
#
# Antrea's datapath is OVS, so pod-to-pod traffic crosses the tunnel whether or
# not this holds - the traceflow above passes either way. What breaks silently
# is everything antrea does with iptables: the NOTRACK rules in the raw table,
# masquerading, NodePort. It logs and retries every 60s and nothing else says a
# word.
#
# Both halves are asserted because both have failed. The binary went missing
# when two nodes shared a containers/storage and one CRI-O deleted the other's
# layers, leaving a container whose lookups resolved from cache while readdir
# returned nothing. And the backend matters on its own: the image ships
# xtables-nft-multi and xtables-legacy-multi, and a resolution to legacy on an
# nft host means antrea writes rules nothing consults.
for node in "$CP_NODE" "${WORKERS[@]}"; do
  agent=$(kubectl -n kube-system get pods -l component=antrea-agent \
          --field-selector "spec.nodeName=${node}" \
          -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -z "$agent" ]; then
    echo "❌ ${node} runs no antrea-agent"
    exit 1
  fi

  if ! ver=$(kubectl -n kube-system exec "$agent" -c antrea-agent -- \
             iptables --version 2>&1); then
    echo "❌ ${agent} on ${node} cannot run iptables: ${ver}"
    kubectl -n kube-system exec "$agent" -c antrea-agent -- \
      sh -c 'echo "   /usr/sbin entries: $(ls /usr/sbin 2>/dev/null | wc -l)"' 2>&1 || true
    exit 1
  fi

  case "$ver" in
    *nf_tables*) echo "✅ ${node}: antrea programs nftables (${ver})" ;;
    *) echo "❌ ${node}: antrea resolved iptables to ${ver}, not the nft backend"
       exit 1 ;;
  esac
done

echo ""
echo "✅ Cluster is multi-node and pod traffic crosses its nodes"
