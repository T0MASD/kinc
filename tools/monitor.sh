                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            #!/bin/bash
set -euo pipefail

echo "🔍 kinc Rootless Cluster Monitor"
echo "================================"

# Configuration: Cluster name
CLUSTER_NAME="${CLUSTER_NAME:-default}"
CONTAINER_NAME="kinc-${CLUSTER_NAME}-control-plane"
echo "🏷️  Monitoring cluster: $CLUSTER_NAME"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Timeout settings (in seconds)
CONTAINER_TIMEOUT=30
SERVICE_TIMEOUT=60
CLUSTER_TIMEOUT=120
TOTAL_TIMEOUT=300

START_TIME=$(date +%s)

# Helper functions
print_status() {
    local status=$1
    local message=$2
    case $status in
        "WAIT") echo -e "${YELLOW}⏳ $message${NC}" ;;
        "OK")   echo -e "${GREEN}✅ $message${NC}" ;;
        "FAIL") echo -e "${RED}❌ $message${NC}" ;;
        "INFO") echo -e "${BLUE}ℹ️  $message${NC}" ;;
    esac
}

wait_for_condition() {
    local description=$1
    local check_command=$2
    local timeout=${3:-30}
    local interval=${4:-2}
    
    print_status "WAIT" "Waiting for: $description"
    
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        if eval "$check_command" >/dev/null 2>&1; then
            print_status "OK" "$description (${elapsed}s)"
            return 0
        fi
        sleep $interval
        elapsed=$((elapsed + interval))
        echo -n "."
    done
    
    echo
    print_status "FAIL" "$description (timeout after ${timeout}s)"
    return 1
}

check_elapsed_time() {
    local current_time=$(date +%s)
    local elapsed=$((current_time - START_TIME))
    if [ $elapsed -gt $TOTAL_TIMEOUT ]; then
        print_status "FAIL" "Total timeout exceeded (${elapsed}s > ${TOTAL_TIMEOUT}s)"
        exit 1
    fi
    echo -e "${BLUE}⏱️  Elapsed: ${elapsed}s${NC}"
}

# Step 1: Check if container service is running
echo
print_status "INFO" "Step 1: Container Service Status"
wait_for_condition "Container service active" \
    "systemctl --user is-active kinc-${CLUSTER_NAME}-control-plane.service" \
    $CONTAINER_TIMEOUT

# Step 2: Check if container is responding
echo
print_status "INFO" "Step 2: Container Responsiveness"
wait_for_condition "Container responding to commands" \
    "podman exec ${CONTAINER_NAME} echo 'ok'" \
    $CONTAINER_TIMEOUT

# Step 3: Check IP forwarding (critical for networking)
echo
print_status "INFO" "Step 3: Network Prerequisites"
if ! wait_for_condition "Host IP forwarding enabled" \
    "test \$(cat /proc/sys/net/ipv4/ip_forward) -eq 1" \
    5; then
    echo
    echo "💡 IP forwarding is required for rootless container networking."
    echo "   To enable it, run: echo 1 | sudo tee /proc/sys/net/ipv4/ip_forward"
    echo "   Or permanently: echo 'net.ipv4.ip_forward = 1' | sudo tee -a /etc/sysctl.conf"
    echo
    exit 1
fi

# Step 4: Check systemd inside container
echo
print_status "INFO" "Step 4: Container Systemd Status"
wait_for_condition "Container systemd operational" \
    "podman exec ${CONTAINER_NAME} systemctl is-system-running --wait" \
    $SERVICE_TIMEOUT

# Step 5: Check cgroup setup service
echo
print_status "INFO" "Step 5: Cgroup Controller Setup"
wait_for_condition "Cgroup setup service completed" \
    "podman exec ${CONTAINER_NAME} systemctl is-active kinc-cgroup-setup.service" \
    $SERVICE_TIMEOUT

# Step 6: Check CRI-O service
echo
print_status "INFO" "Step 6: Container Runtime (CRI-O)"
wait_for_condition "CRI-O service active" \
    "podman exec ${CONTAINER_NAME} systemctl is-active crio.service" \
    $SERVICE_TIMEOUT

wait_for_condition "CRI-O socket available" \
    "podman exec ${CONTAINER_NAME} test -S /var/run/crio/crio.sock" \
    $SERVICE_TIMEOUT

# Step 7: Check kubelet service
echo
print_status "INFO" "Step 7: Kubelet Service"
wait_for_condition "Kubelet service active" \
    "podman exec ${CONTAINER_NAME} systemctl is-active kubelet.service" \
    $SERVICE_TIMEOUT

# Step 8: Check cluster initialization service
echo
print_status "INFO" "Step 8: Cluster Initialization"
wait_for_condition "Cluster init service started" \
    "podman exec ${CONTAINER_NAME} systemctl is-active kinc-init.service" \
    $CLUSTER_TIMEOUT

# Step 9: Check API server availability
echo
print_status "INFO" "Step 9: Kubernetes API Server"
wait_for_condition "API server responding" \
    "podman exec ${CONTAINER_NAME} kubectl --kubeconfig=/etc/kubernetes/admin.conf cluster-info" \
    $CLUSTER_TIMEOUT

# Step 10: Check node readiness
echo
print_status "INFO" "Step 10: Node Readiness"
wait_for_condition "Node ready" \
    "podman exec ${CONTAINER_NAME} kubectl --kubeconfig=/etc/kubernetes/admin.conf wait --for=condition=Ready nodes --all --timeout=10s" \
    $CLUSTER_TIMEOUT

# Step 11: Check core system pods
echo
print_status "INFO" "Step 11: Core System Pods"
wait_for_condition "etcd pod running" \
    "podman exec ${CONTAINER_NAME} kubectl --kubeconfig=/etc/kubernetes/admin.conf get pod -n kube-system -l component=etcd --field-selector=status.phase=Running" \
    $CLUSTER_TIMEOUT

wait_for_condition "API server pod running" \
    "podman exec ${CONTAINER_NAME} kubectl --kubeconfig=/etc/kubernetes/admin.conf get pod -n kube-system -l component=kube-apiserver --field-selector=status.phase=Running" \
    $CLUSTER_TIMEOUT

wait_for_condition "Controller manager pod running" \
    "podman exec ${CONTAINER_NAME} kubectl --kubeconfig=/etc/kubernetes/admin.conf get pod -n kube-system -l component=kube-controller-manager --field-selector=status.phase=Running" \
    $CLUSTER_TIMEOUT

wait_for_condition "Scheduler pod running" \
    "podman exec ${CONTAINER_NAME} kubectl --kubeconfig=/etc/kubernetes/admin.conf get pod -n kube-system -l component=kube-scheduler --field-selector=status.phase=Running" \
    $CLUSTER_TIMEOUT

# Step 12: Check CNI
echo
print_status "INFO" "Step 12: Container Network Interface (CNI)"
wait_for_condition "CNI pods running" \
    "podman exec ${CONTAINER_NAME} kubectl --kubeconfig=/etc/kubernetes/admin.conf get pod -n kube-system -l k8s-app=kincnet --field-selector=status.phase=Running" \
    $CLUSTER_TIMEOUT

# Step 13: Check storage provisioner
echo
print_status "INFO" "Step 13: Storage Provisioner"
wait_for_condition "Storage provisioner running" \
    "podman exec ${CONTAINER_NAME} kubectl --kubeconfig=/etc/kubernetes/admin.conf get pod -n local-path-storage -l app=local-path-provisioner --field-selector=status.phase=Running" \
    $CLUSTER_TIMEOUT

# Step 14: Check DNS (CoreDNS)
echo
print_status "INFO" "Step 14: DNS Service (CoreDNS)"
wait_for_condition "CoreDNS pods running" \
    "podman exec ${CONTAINER_NAME} kubectl --kubeconfig=/etc/kubernetes/admin.conf get pod -n kube-system -l k8s-app=kube-dns --field-selector=status.phase=Running" \
    $CLUSTER_TIMEOUT

# Final status check
echo
print_status "INFO" "Final Status Check"
check_elapsed_time

echo
echo "📊 Cluster Status Summary:"
echo "========================="

# Node status
echo "🖥️  Node Status:"
podman exec ${CONTAINER_NAME} kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes

echo
echo "🏃 Running Pods:"
podman exec ${CONTAINER_NAME} kubectl --kubeconfig=/etc/kubernetes/admin.conf get pods -A --field-selector=status.phase=Running

echo
echo "📦 Storage Classes:"
podman exec ${CONTAINER_NAME} kubectl --kubeconfig=/etc/kubernetes/admin.conf get storageclass

# Calculate total time
END_TIME=$(date +%s)
TOTAL_TIME=$((END_TIME - START_TIME))

echo
print_status "OK" "Cluster initialization completed in ${TOTAL_TIME} seconds!"

echo
echo "🧪 Next steps:"
echo "  - Run tests: ./tools/test.sh"
echo "  - Deploy workloads: kubectl apply -f your-manifest.yaml"
echo "  - Monitor: kubectl get pods -A --watch"
echo
echo "🛑 To cleanup:"
echo "  ./tools/cleanup.sh"
