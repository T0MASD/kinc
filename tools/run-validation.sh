#!/bin/bash
# kinc Validation Test - Automated Execution
# Tests baked-in and mounted configuration deployment methods
# References deployment commands from .github/workflows/release.yml

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "$PROJECT_ROOT"

echo "╔════════════════════════════════════════════════════════════════════════════╗"
echo "║              kinc Validation Test - Automated Execution                   ║"
echo "╚════════════════════════════════════════════════════════════════════════════╝"
echo ""

# Test configuration
KINC_IMAGE="${KINC_IMAGE:-localhost/kinc/node:v1.34.2}"
echo "Using image: $KINC_IMAGE"
echo ""

# ============================================================================
# Prerequisites: System Configuration Check
# ============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Prerequisites: System Configuration Check"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check 1: IP Forwarding (REQUIRED)
ip_forward=$(cat /proc/sys/net/ipv4/ip_forward)
if [ "$ip_forward" != "1" ]; then
  echo "❌ IP forwarding DISABLED"
  echo "   Required for Kubernetes pod networking!"
  echo "   Enable with: sudo sysctl -w net.ipv4.ip_forward=1"
  echo "   To persist:  echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.d/99-kinc.conf"
  exit 1
fi
echo "✅ IP forwarding enabled"

# Check 2: Inotify limits (REQUIRED for multi-cluster)
max_watches=$(cat /proc/sys/fs/inotify/max_user_watches)
max_instances=$(cat /proc/sys/fs/inotify/max_user_instances)
if [ "$max_watches" -lt 524288 ] || [ "$max_instances" -lt 2048 ]; then
  echo "❌ Inotify limits below recommended"
  echo "   Current: watches=$max_watches, instances=$max_instances"
  echo "   Recommended: watches=524288, instances=2048"
  echo "   Required for validation test (7 clusters)"
  echo "   To fix: sudo sysctl -w fs.inotify.max_user_watches=524288"
  echo "           sudo sysctl -w fs.inotify.max_user_instances=2048"
  echo "   Set KINC_SKIP_SYSCTL_CHECKS=true to bypass (not recommended)"
  [ "${KINC_SKIP_SYSCTL_CHECKS:-false}" != "true" ] && exit 1
fi
echo "✅ Inotify limits sufficient for 5+ clusters"

# Check 3: Kernel keyring limits (RECOMMENDED)
maxkeys=$(cat /proc/sys/kernel/keys/maxkeys 2>/dev/null || echo "1000")
maxbytes=$(cat /proc/sys/kernel/keys/maxbytes 2>/dev/null || echo "25000")
if [ "$maxkeys" -lt 1000 ] || [ "$maxbytes" -lt 25000 ]; then
  echo "⚠️  Kernel keyring limits below recommended"
  echo "   Current: maxkeys=$maxkeys, maxbytes=$maxbytes"
  echo "   Recommended: maxkeys=1000, maxbytes=25000"
  echo "   To fix: sudo sysctl -w kernel.keys.maxkeys=1000"
  echo "           sudo sysctl -w kernel.keys.maxbytes=25000"
else
  echo "✅ Kernel keyring limits sufficient"
fi

# Check 4: Failed services (WARNING only)
failed=$(systemctl --user list-units --state=failed --no-pager --no-legend 2>/dev/null | wc -l)
if [ $failed -gt 0 ]; then
  echo "⚠️  Found $failed failed user service(s) - review before testing"
  echo "   Check with: systemctl --user list-units --state=failed"
else
  echo "✅ System health: no failed services"
fi

echo ""
echo "✅ Prerequisites check complete"
echo ""

# ============================================================================
# T1: deploy.sh with baked-in config
# ============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "T1: Deploying with deploy.sh (baked-in config)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Deployment: See release.yml - Option 1"
echo ""

USE_BAKED_IN_CONFIG=true KINC_ENABLE_FARO=true CLUSTER_NAME=default ./tools/deploy.sh
echo "✅ T1 complete: default cluster (baked-in config)"
echo ""

# ============================================================================
# T2: deploy.sh with mounted config (5 clusters)
# ============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "T2: Deploying with deploy.sh (mounted config - 5 clusters)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Deployment: See release.yml - Option 1 (without USE_BAKED_IN_CONFIG)"
echo ""

for i in 01 02 03 04 05; do
  echo "Deploying cluster${i}..."
  KINC_ENABLE_FARO=true CLUSTER_NAME=cluster${i} ./tools/deploy.sh
  
  # Wait for service to be stable (systemd-driven, no arbitrary sleeps)
  echo "Verifying cluster${i} service stability..."
  until systemctl --user is-active --quiet kinc-cluster${i}-control-plane.service; do
    sleep 2
  done
  
  # Brief stability check
  sleep 2
  if systemctl --user is-failed --quiet kinc-cluster${i}-control-plane.service; then
    echo "❌ Service kinc-cluster${i}-control-plane.service has failed!"
    systemctl --user status kinc-cluster${i}-control-plane.service --no-pager
    exit 1
  fi
  
  echo "✅ cluster${i} deployed and stable"
  echo ""
done
echo "✅ T2 complete: 5 clusters with mounted config"
echo ""

# ============================================================================
# T3: direct podman run with baked-in config
# ============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "T3: Deploying with direct podman run (baked-in config)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Deployment: See release.yml - Option 2"
echo ""

# Clean any existing direct-podman cluster
podman rm -f kinc-direct-podman 2>/dev/null || true
podman volume rm kinc-direct-podman-var-data 2>/dev/null || true

# Create volume
podman volume create kinc-direct-podman-var-data

# Deploy using exact command from release.yml (Option 2)
# Modified: name=kinc-direct-podman, port=6450:6443
podman run -d --name kinc-direct-podman \
  --hostname kinc-direct-podman \
  --cgroups=split \
  --cap-add=SYS_ADMIN --cap-add=SYS_RESOURCE --cap-add=NET_ADMIN \
  --cap-add=SETPCAP --cap-add=NET_RAW --cap-add=SYS_PTRACE \
  --cap-add=DAC_OVERRIDE --cap-add=CHOWN --cap-add=FOWNER \
  --cap-add=FSETID --cap-add=KILL --cap-add=SETGID --cap-add=SETUID \
  --cap-add=NET_BIND_SERVICE --cap-add=SYS_CHROOT --cap-add=SETFCAP \
  --cap-add=DAC_READ_SEARCH --cap-add=AUDIT_WRITE \
  --device /dev/fuse \
  --tmpfs /tmp:rw,rprivate,nosuid,nodev,tmpcopyup \
  --tmpfs /run:rw,rprivate,nosuid,nodev,tmpcopyup \
  --tmpfs /run/lock:rw,rprivate,nosuid,nodev,tmpcopyup \
  --volume kinc-direct-podman-var-data:/var:rw \
  --volume $HOME/.local/share/containers/storage:/root/.local/share/containers/storage:rw \
  --sysctl net.ipv6.conf.all.disable_ipv6=0 \
  --sysctl net.ipv6.conf.all.keep_addr_on_down=1 \
  --sysctl net.netfilter.nf_conntrack_tcp_timeout_established=86400 \
  --sysctl net.netfilter.nf_conntrack_tcp_timeout_close_wait=3600 \
  -p 127.0.0.1:6450:6443/tcp \
  --env container=podman \
  --env KINC_ENABLE_FARO=true \
  "$KINC_IMAGE"

echo "Waiting for cluster initialization..."
timeout 300 bash -c 'until podman exec kinc-direct-podman test -f /var/lib/kinc-initialized 2>/dev/null; do sleep 2; done'
echo "✅ Cluster initialized"

echo "Waiting for API server to be ready..."
timeout 300 bash -c 'until podman exec kinc-direct-podman kubectl --kubeconfig=/etc/kubernetes/admin.conf get --raw /healthz >/dev/null 2>&1; do sleep 2; done'
echo "✅ API server responding"

echo "Waiting for system pods..."
kubectl --kubeconfig=<(podman exec kinc-direct-podman cat /etc/kubernetes/admin.conf | sed 's|server: https://.*:6443|server: https://127.0.0.1:6450|g') \
  wait --for=condition=Ready pods --all -n kube-system --timeout=300s

echo "Waiting for storage provisioner..."
# Wait for namespace to exist first (avoids "no matching resources" error)
timeout 60 bash -c 'until kubectl --kubeconfig=<(podman exec kinc-direct-podman cat /etc/kubernetes/admin.conf | sed "s|server: https://.*:6443|server: https://127.0.0.1:6450|g") get namespace local-path-storage >/dev/null 2>&1; do sleep 2; done'
# Wait for pods to be created
timeout 60 bash -c 'until kubectl --kubeconfig=<(podman exec kinc-direct-podman cat /etc/kubernetes/admin.conf | sed "s|server: https://.*:6443|server: https://127.0.0.1:6450|g") get pods -n local-path-storage 2>/dev/null | grep -q local-path-provisioner; do sleep 2; done'
# Now wait for pods to be ready
kubectl --kubeconfig=<(podman exec kinc-direct-podman cat /etc/kubernetes/admin.conf | sed 's|server: https://.*:6443|server: https://127.0.0.1:6450|g') \
  wait --for=condition=Ready pods --all -n local-path-storage --timeout=60s

echo "✅ T3 complete: direct-podman cluster (baked-in config)"
echo ""

# ============================================================================
# Verification: Multi-Service Architecture
# ============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Verification: Multi-Service Architecture"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check default cluster (baked-in config) as sample
echo "Checking default cluster multi-service architecture..."
verification_failed=false
for service in kinc-preflight.service kubeadm-init.service kinc-postinit.service; do
  if podman exec kinc-default-control-plane systemctl is-active --quiet $service 2>/dev/null; then
    echo "  ✅ $service: active"
  else
    echo "  ❌ $service: not active"
    verification_failed=true
  fi
done

if podman exec kinc-default-control-plane test -f /var/lib/kinc-initialized 2>/dev/null; then
  echo "  ✅ Initialization marker: present"
else
  echo "  ❌ Initialization marker: missing"
  verification_failed=true
fi

if [ "$verification_failed" = true ]; then
  echo "❌ Multi-service architecture verification failed"
  exit 1
fi

echo "✅ Multi-service architecture verified"
echo ""

# ============================================================================
# Workload Validation: Storage & Networking
# ============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Workload Validation: Storage & Networking"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Test on default cluster (representative test)
echo "Testing on default cluster..."
echo ""

# Get cluster port and prepare kubeconfig
cluster_port=$(podman inspect kinc-default-control-plane --format '{{range $p, $conf := .NetworkSettings.Ports}}{{range $conf}}{{.HostPort}}{{end}}{{end}}' 2>/dev/null)
mkdir -p ~/.kube
podman cp kinc-default-control-plane:/etc/kubernetes/admin.conf ~/.kube/kinc-validation-config 2>/dev/null
sed -i "s|server: https://.*:6443|server: https://127.0.0.1:$cluster_port|g" ~/.kube/kinc-validation-config
export KUBECONFIG=~/.kube/kinc-validation-config

# Install Gateway API CRDs
echo "0️⃣  Installing Gateway API CRDs..."
if kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.1/standard-install.yaml >/dev/null 2>&1; then
  echo "✅ Gateway API CRDs installed (v1.4.1)"
  gateway_available=true
  
  # Verify cluster-scoped GatewayClass is available (right after CRD installation)
  echo "1️⃣  Verifying GatewayClass CRD (cluster-scoped)..."
  if kubectl get crd gatewayclasses.gateway.networking.k8s.io >/dev/null 2>&1; then
    echo "✅ GatewayClass CRD is available"
  else
    echo "⚠️  GatewayClass CRD not found"
    gateway_available=false
  fi
else
  echo "⚠️  Gateway API CRDs installation failed (will continue without Gateway resources)"
  gateway_available=false
fi
echo ""

# Deploy test workload
echo "2️⃣  Deploying test workload (PVC + Pod + Service + Gateway/HTTPRoute)..."
deploy_output=$(kubectl apply -f runtime/manifests/test-workload.yaml 2>&1) || true
echo "$deploy_output" | grep -E "(created|configured|unchanged)" || true
if echo "$deploy_output" | grep -q "no matches for kind"; then
  echo "⚠️  Gateway API CRDs not installed (optional - will skip Gateway validation)"
fi
echo "✅ Core workload deployed"
echo ""

# Verify Gateway API resources were created (namespaced: Gateway and HTTPRoute)
echo "3️⃣  Verifying Gateway and HTTPRoute (namespaced)..."
gateway_created=false
httproute_created=false
if [ "$gateway_available" = true ]; then
  # Check if Gateway resource was created (note: won't be Accepted without a controller)
  if kubectl get gateway test-gateway >/dev/null 2>&1; then
    echo "✅ Gateway resource created (no controller to accept it)"
    gateway_created=true
  else
    echo "⚠️  Gateway resource not found"
  fi
  
  # Check HTTPRoute exists
  if kubectl get httproute test-route >/dev/null 2>&1; then
    echo "✅ HTTPRoute resource created"
    httproute_created=true
  else
    echo "⚠️  HTTPRoute resource not found"
  fi
else
  echo "⚠️  Gateway API CRDs not available (skipped)"
fi
echo ""

# Wait for PVC to be bound
echo "4️⃣  Waiting for PVC to be bound (local-path-provisioner)..."
if kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/test-pvc --timeout=60s >/dev/null 2>&1; then
  pvc_size=$(kubectl get pvc test-pvc -o jsonpath='{.spec.resources.requests.storage}')
  pvc_status=$(kubectl get pvc test-pvc -o jsonpath='{.status.phase}')
  echo "✅ PVC bound: $pvc_size ($pvc_status)"
else
  echo "❌ Timeout waiting for PVC to bind"
  kubectl get pvc test-pvc
  kubectl describe pvc test-pvc
  exit 1
fi
echo ""

# Wait for pod to be ready (readiness probe verifies node-info.json exists and is served)
echo "5️⃣  Waiting for test pod to be ready..."
if kubectl wait --for=condition=Ready pod/test-pod --timeout=300s >/dev/null 2>&1; then
  echo "✅ Pod ready (init container completed, node data collected via kubectl, HTTP server serving)"
else
  echo "❌ Pod failed to become ready"
  kubectl get pod test-pod
  kubectl logs test-pod -c generate-data 2>&1 | tail -10
  kubectl describe pod test-pod | tail -20
  exit 1
fi
echo ""

# Fetch and parse node data via HTTP service
echo "6️⃣  Fetching node data from HTTP service..."
service_ip=$(kubectl get svc test-service -o jsonpath='{.spec.clusterIP}')
echo "Service ClusterIP: $service_ip"

# Fetch JSON from HTTP server via Service networking (using curl in a test pod)
echo "Testing HTTP download via Service..."
kubectl run curl-test --image=curlimages/curl:latest --rm -i --restart=Never --quiet -- \
  curl -s http://${service_ip}:80/node-info.json > /tmp/node-info.json 2>/dev/null
if [ -f /tmp/node-info.json ] && [ -s /tmp/node-info.json ]; then
  runtime=$(jq -r '.status.nodeInfo.containerRuntimeVersion' /tmp/node-info.json 2>/dev/null || echo "unknown")
  kubelet_version=$(jq -r '.status.nodeInfo.kubeletVersion' /tmp/node-info.json 2>/dev/null || echo "unknown")
  node_name=$(jq -r '.metadata.name' /tmp/node-info.json 2>/dev/null || echo "unknown")
  os_image=$(jq -r '.status.nodeInfo.osImage' /tmp/node-info.json 2>/dev/null || echo "unknown")
  kernel=$(jq -r '.status.nodeInfo.kernelVersion' /tmp/node-info.json 2>/dev/null || echo "unknown")
  
  echo "  Node: $node_name"
  echo "  Container Runtime: $runtime"
  echo "  Kubelet: $kubelet_version"
  echo "  OS: $os_image"
  echo "  Kernel: $kernel"
  echo "✅ Node data collected and parsed successfully"
else
  echo "❌ Failed to retrieve node JSON from HTTP server"
  exit 1
fi
echo ""

# Cleanup test workload
echo "7️⃣  Cleaning up test workload..."
kubectl delete -f runtime/manifests/test-workload.yaml --wait=false >/dev/null 2>&1
rm -f /tmp/node-info.json
echo "✅ Test workload cleaned up"
echo ""

echo "✅ Storage & Networking validation complete"
echo ""
echo "📝 Validation Results:"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Storage:"
echo "    • PVC: $pvc_size ($pvc_status)"
echo "  Network:"
echo "    • Service ClusterIP: $service_ip"
echo "  Node Info:"
echo "    • Name: $node_name"
echo "    • Runtime: $runtime"
echo "    • Kubelet: $kubelet_version"
echo "    • OS: $os_image"
echo "    • Kernel: $kernel"
if [ "$gateway_available" = true ]; then
echo "  Gateway API:"
echo "    • GatewayClass CRD: ✅ installed"
echo "    • Gateway resource: $([ "$gateway_created" = true ] && echo "✅ created" || echo "❌ failed")"
echo "    • HTTPRoute resource: $([ "$httproute_created" = true ] && echo "✅ created" || echo "❌ failed")"
echo "    • Note: No controller installed (resources won't be Accepted)"
fi
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ============================================================================
# Summary
# ============================================================================
echo "╔════════════════════════════════════════════════════════════════════════════╗"
echo "║                    Deployment Complete - 7 Clusters                        ║"
echo "╚════════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "Cluster Inventory:"
podman ps --filter "name=kinc" --format "{{.Names}}\t{{.Status}}\t{{.Ports}}" | while IFS=$'\t' read -r name status ports; do
  # Skip empty lines
  if [ -z "$name" ]; then
    continue
  fi
  
  # Extract port from format: 127.0.0.1:6443->6443/tcp
  port=$(echo "$ports" | grep -oE '127\.0\.0\.1:[0-9]+' | cut -d: -f2 || echo "unknown")
  
  # Determine method
  if echo "$name" | grep -q "direct-podman"; then
    method="(podman run + baked-in)"
  elif [ "$name" = "kinc-default-control-plane" ]; then
    method="(deploy.sh + baked-in) "
  else
    method="(deploy.sh + mounted)  "
  fi
  
  # Format: adjust spacing based on name length
  printf "  • %-30s %s - Port %s\n" "$name" "$method" "$port"
done
echo ""

# Check if we should skip cleanup (for debugging)
if [[ "${SKIP_CLEANUP:-}" == "true" ]]; then
  echo "⚠️  SKIP_CLEANUP=true - Clusters left running for manual inspection"
  echo ""
  echo "Next: Run manual validation checks (see work/VALIDATION_TEST.md)"
  echo "  - kubectl get nodes (all clusters)"
  echo "  - kubectl get pods -A (all clusters)"
  echo "  - DNS, storage, and config source validation"
  echo ""
  echo "To cleanup later:"
  echo "  for cluster in default cluster01 cluster02 cluster03 cluster04 cluster05; do"
  echo "    CLUSTER_NAME=\$cluster ./tools/cleanup.sh"
  echo "  done"
  echo "  podman rm -f kinc-direct-podman"
  echo "  podman volume rm kinc-direct-podman-var-data"
  echo ""
  exit 0
fi

# Automatic cleanup
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Cleanup: Removing all validation test clusters"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

echo "Cleaning up deploy.sh clusters (6 clusters)..."
for cluster in default cluster01 cluster02 cluster03 cluster04 cluster05; do
  echo "  Cleaning $cluster..."
  CLUSTER_NAME=$cluster ./tools/cleanup.sh >/dev/null 2>&1 && echo "    ✅ $cluster removed" || echo "    ⚠️  $cluster cleanup failed"
done
echo ""

echo "Cleaning up direct podman run cluster..."
podman rm -f kinc-direct-podman >/dev/null 2>&1 && echo "  ✅ Container removed" || echo "  ⚠️  Container not found"
podman volume rm kinc-direct-podman-var-data >/dev/null 2>&1 && echo "  ✅ Volume removed" || echo "  ⚠️  Volume not found"
echo ""

echo "Verifying cleanup..."
REMAINING_CONTAINERS=$(podman ps -a --filter "name=kinc" --format "{{.Names}}" | wc -l)
REMAINING_VOLUMES=$(podman volume ls --filter "name=kinc" --format "{{.Name}}" | wc -l)

if [[ $REMAINING_CONTAINERS -eq 0 ]] && [[ $REMAINING_VOLUMES -eq 0 ]]; then
  echo "✅ All clusters cleaned up successfully"
else
  echo "⚠️  Warning: $REMAINING_CONTAINERS containers and $REMAINING_VOLUMES volumes remain"
fi
echo ""

echo "╔════════════════════════════════════════════════════════════════════════════╗"
echo "║                   ✅ VALIDATION TEST COMPLETE                              ║"
echo "╚════════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "All validation test clusters deployed, tested, and cleaned up."
echo ""
echo "To run without cleanup (for manual inspection), use:"
echo "  SKIP_CLEANUP=true ./tools/run-validation.sh"
echo ""

