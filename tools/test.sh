#!/bin/bash
set -euo pipefail

echo "🧪 kinc Rootless Cluster Testing"
echo "================================"

# Configuration: Cluster name
CLUSTER_NAME="${CLUSTER_NAME:-default}"
CONTAINER_NAME="kinc-${CLUSTER_NAME}-control-plane"
echo "🏷️  Testing cluster: $CLUSTER_NAME"

# Test 1: Deploy test workload
echo
echo "📦 Test 1: Deploying test workload"
podman cp runtime/manifests/test-workload.yaml ${CONTAINER_NAME}:/tmp/
podman exec ${CONTAINER_NAME} kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f /tmp/test-workload.yaml
echo "✅ Test workload deployed"

# Wait for pod to be ready
echo
echo "⏳ Waiting for pod to be ready..."
podman exec ${CONTAINER_NAME} kubectl --kubeconfig=/etc/kubernetes/admin.conf wait --for=condition=Ready pod/test-pod --timeout=60s

# Test 2: Check pod and PVC status
echo
echo "🔍 Test 2: Checking pod and PVC status"
podman exec ${CONTAINER_NAME} kubectl --kubeconfig=/etc/kubernetes/admin.conf get pods,pvc

# Test 3: Test storage
echo
echo "💾 Test 3: Testing storage"
podman exec ${CONTAINER_NAME} kubectl --kubeconfig=/etc/kubernetes/admin.conf exec test-pod -- sh -c "echo 'Hello from kinc rootless!' > /data/test.txt && cat /data/test.txt"

# Test 4: Test networking (DNS)
echo
echo "🌐 Test 4: Testing networking (DNS)"
podman exec ${CONTAINER_NAME} kubectl --kubeconfig=/etc/kubernetes/admin.conf exec test-pod -- nslookup kubernetes.default.svc.cluster.local

echo
echo "✅ All tests passed! Cluster is fully operational."
