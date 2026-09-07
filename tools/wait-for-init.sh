#!/bin/bash
set -euo pipefail

# Wait for kinc-init.service to complete in a cluster
# Usage: ./wait-for-init.sh CLUSTER_NAME [TIMEOUT_SECONDS]

CLUSTER_NAME="${1:-}"
TIMEOUT="${2:-1500}"  # Default 25 minutes (allows for worst-case kubectl wait timeouts in CI)

if [[ -z "$CLUSTER_NAME" ]]; then
    echo "Usage: $0 CLUSTER_NAME [TIMEOUT_SECONDS]" >&2
    exit 1
fi

CONTAINER_NAME="kinc-${CLUSTER_NAME}-control-plane"
elapsed=0

echo "⏳ Waiting for ${CLUSTER_NAME} initialization (timeout: ${TIMEOUT}s)..."

while [[ $elapsed -lt $TIMEOUT ]]; do
    # Check if container is running
    if ! podman ps --filter "name=${CONTAINER_NAME}" --format "{{.Names}}" | grep -q "${CONTAINER_NAME}"; then
        echo "❌ Container ${CONTAINER_NAME} is not running" >&2
        exit 1
    fi
    
    # Check kinc-init.service status
    # Note: Type=oneshot services show "active" when completed successfully
    status=$(podman exec "${CONTAINER_NAME}" systemctl is-active kinc-init.service 2>/dev/null || echo "unknown")
    sub_state=$(podman exec "${CONTAINER_NAME}" systemctl show kinc-init.service -p SubState --value 2>/dev/null || echo "unknown")
    
    case "$status" in
        "active")
            # For oneshot services, "active" means completed
            # Check SubState to confirm it's "exited" not "running"
            if [[ "$sub_state" == "exited" ]]; then
                # Verify it succeeded
                exit_status=$(podman exec "${CONTAINER_NAME}" systemctl show kinc-init.service -p Result --value 2>/dev/null || echo "unknown")
                if [[ "$exit_status" == "success" ]]; then
                    echo "✅ ${CLUSTER_NAME} initialization completed successfully (${elapsed}s)"
                    exit 0
                else
                    echo "❌ ${CLUSTER_NAME} initialization completed with result: ${exit_status}" >&2
                    exit 1
                fi
            fi
            # If SubState is not "exited", service is still running, continue waiting
            ;;
        "inactive")
            # Service hasn't started yet or was stopped
            ;;
        "failed")
            echo "❌ ${CLUSTER_NAME} initialization failed" >&2
            # Show last few log lines for debugging
            echo "Last 10 log lines:" >&2
            podman exec "${CONTAINER_NAME}" journalctl -u kinc-init.service --no-pager -n 10 2>/dev/null || true
            exit 1
            ;;
        "activating")
            # Still starting up, continue waiting
            ;;
        "reloading"|"deactivating")
            # Transitioning state, wait
            ;;
        *)
            # Unknown state (container might be starting up)
            # Wait a bit before checking again
            ;;
    esac
    
    sleep 2
    elapsed=$((elapsed + 2))
    
    # Progress indicator every 30 seconds
    if [[ $((elapsed % 30)) -eq 0 ]] && [[ $elapsed -lt $TIMEOUT ]]; then
        echo "  Still initializing... (${elapsed}/${TIMEOUT}s)"
    fi
done

echo "❌ ${CLUSTER_NAME} initialization timed out after ${TIMEOUT}s" >&2
exit 1

