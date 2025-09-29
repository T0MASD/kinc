# kinc - Kubernetes in Container

**kinc** is a rootless, single-container Kubernetes distribution designed for development, testing, and edge deployments. It provides a complete Kubernetes cluster running entirely in userspace without requiring root privileges or complex multi-container orchestration.

## Architecture Overview

kinc packages a complete Kubernetes v1.33.5 cluster into a single container image, featuring:

- **Rootless Operation**: Runs entirely in userspace without root privileges
- **Single Container**: All components (etcd, API server, kubelet, etc.) in one container
- **Multi-Cluster Support**: Deploy multiple isolated clusters concurrently
- **Podman Quadlet Integration**: Native systemd service management
- **Dynamic Resource Allocation**: Automatic port and CIDR management

## Core Components

### Container Runtime Stack
- **Base OS**: Fedora 42
- **Container Runtime**: CRI-O 1.33 with rootless configuration
- **Low-Level Runtime**: crun with custom wrapper for rootless compatibility
- **Init System**: systemd for service orchestration

### Kubernetes Components
- **Kubernetes**: v1.33.5 (kubeadm, kubelet, kubectl)
- **CNI**: kincnet (custom bridge-based networking)
- **Storage**: local-path-provisioner for dynamic PV provisioning
- **DNS**: CoreDNS for service discovery

### Rootless Enablement Technologies

#### crun Wrapper
kinc includes a sophisticated crun wrapper (`/usr/local/bin/crun-wrapper.sh`) that:
- Removes `oomScoreAdj` settings that fail in rootless environments
- Strips problematic user settings to avoid capset issues
- Handles helper container capability restrictions
- Uses jq for safe JSON manipulation of OCI specs

#### Cgroup Management
Automated cgroup v2 setup via `kinc-cgroup-setup.service`:
- Enables necessary cgroup controllers (cpu, memory, pids, io)
- Configures cgroup delegation for rootless operation
- Handles systemd slice configuration

#### Network Configuration
- Custom CNI plugin (kincnet) optimized for rootless containers
- Automatic IP forwarding validation and setup
- Dynamic CIDR allocation to prevent cluster conflicts

## Multi-Cluster Architecture

### Sequential Resource Allocation
kinc uses environment inspection for deterministic resource allocation:

```bash
# Port allocation based on existing clusters
Port 6443 → Default cluster
Port 6444 → First custom cluster  
Port 6445 → Second custom cluster
...
```

### CIDR Mapping
Network subnets are derived from API server ports:
```bash
Port 6443 → Pod: 10.244.43.0/24, Service: 10.43.0.0/16
Port 6444 → Pod: 10.244.44.0/24, Service: 10.44.0.0/16
Port 6445 → Pod: 10.244.45.0/24, Service: 10.45.0.0/16
```

### Cluster Isolation
Each cluster gets:
- Unique container name: `kinc-{cluster-name}-control-plane`
- Dedicated Podman volumes: `kinc-{cluster-name}-var-data`, `kinc-{cluster-name}-config`
- Isolated systemd services: `kinc-{cluster-name}-control-plane.service`
- Separate network namespaces with non-overlapping IP ranges

## Quick Start

### Prerequisites
- Podman 4.0+ with rootless configuration
- systemd user services enabled
- IP forwarding enabled: `echo 1 | sudo tee /proc/sys/net/ipv4/ip_forward`

### Deploy Default Cluster
```bash
# Full deployment with monitoring and testing
./tools/full-deploy.sh

# Or step-by-step
./tools/build.sh
./tools/deploy.sh
./tools/monitor.sh
./tools/test.sh
```

### Deploy Multiple Clusters
```bash
# Deploy named clusters
CLUSTER_NAME=dev ./tools/full-deploy.sh
CLUSTER_NAME=staging ./tools/full-deploy.sh
CLUSTER_NAME=prod ./tools/full-deploy.sh

# Clusters run concurrently on different ports
# dev: https://127.0.0.1:6444
# staging: https://127.0.0.1:6445  
# prod: https://127.0.0.1:6446
```

### Cleanup
```bash
# Clean up specific cluster
CLUSTER_NAME=dev ./tools/cleanup.sh

# Clean up default cluster
./tools/cleanup.sh
```

## Configuration

### Environment Variables
- `CLUSTER_NAME`: Cluster identifier (default: "default")
- `FORCE_PORT`: Override automatic port allocation
- `CACHE_BUST`: Force package updates during build

### Quadlet Integration
kinc uses Podman Quadlet for systemd integration:
- **Volume Files**: `runtime/quadlet/*.volume` - Define persistent storage
- **Container File**: `runtime/quadlet/kinc-control-plane.container` - Container specification
- **Config Volume**: Runtime-mounted `kubeadm.conf` for cluster-specific configuration

### Cluster Configuration
Each cluster uses a dynamically generated `kubeadm.conf`:
- Cluster-specific naming and endpoints
- Dynamic CIDR allocation
- Container IP address templating

## Development Tools

### Build System
```bash
# Build with custom cluster name
CLUSTER_NAME=mytest ./tools/build.sh

# Force package updates
CACHE_BUST=2 ./tools/build.sh
```

### Monitoring
```bash
# Monitor cluster initialization (14 validation steps)
CLUSTER_NAME=dev ./tools/monitor.sh

# Watch cluster status
podman exec kinc-dev-control-plane kubectl get pods -A --watch
```

### Testing
```bash
# Run comprehensive tests
CLUSTER_NAME=dev ./tools/test.sh

# Tests include: storage, networking, DNS, workload deployment
```

## Technical Details

### Rootless Challenges Solved
1. **OOM Score Adjustment**: crun wrapper removes problematic `oomScoreAdj` settings
2. **Capability Management**: Dynamic capability stripping for helper containers
3. **User Namespace Mapping**: Proper UID/GID handling in rootless environments
4. **Cgroup Delegation**: Automated cgroup controller setup for systemd
5. **Network Isolation**: CNI plugin optimized for rootless networking

### Container Image Structure
```
/etc/kinc/
├── scripts/           # Initialization and setup scripts
├── patches/           # Kubernetes component patches
└── config/           # Runtime-mounted cluster configuration

/kinc/manifests/      # Kubernetes manifests (CNI, storage, etc.)
/var/lib/kubelet/     # Kubelet configuration
```

### Service Dependencies
```
kinc-control-plane.service
├── kinc-var-data-volume.service
├── kinc-config-volume.service  
└── Container Runtime
    ├── kinc-cgroup-setup.service
    ├── crio.service
    └── systemd (PID 1)
```

## Networking

### CNI Plugin (kincnet)
- Bridge-based networking with NAT
- Automatic IP address management
- DNS integration with CoreDNS
- Support for NetworkPolicies

### Port Management
- API Server: Dynamic allocation starting from 6443
- Service NodePorts: 30000-32767 (standard Kubernetes range)
- Host Network: Isolated per cluster

## Storage

### Persistent Volumes
- **Provisioner**: local-path-provisioner
- **Storage Class**: `standard` (default)
- **Backend**: Host filesystem via Podman volumes
- **Access Modes**: ReadWriteOnce (RWO)

### Volume Management
- **Data Volume**: `/var` mount for kubelet, etcd, logs
- **Config Volume**: `/etc/kinc/config` for cluster configuration
- **Container Storage**: Shared with host for image management

## Security

### Rootless Security Model
- No root privileges required
- User namespace isolation
- Seccomp and AppArmor integration
- Limited capability sets

### Network Security
- Isolated network namespaces per cluster
- Configurable NetworkPolicies
- No privileged network operations

## Troubleshooting

### Common Issues
1. **IP Forwarding**: Ensure `net.ipv4.ip_forward=1`
2. **Systemd Services**: Check `systemctl --user status kinc-*`
3. **Container Logs**: Use `podman logs kinc-{cluster}-control-plane`
4. **Resource Conflicts**: Verify unique ports with `podman ps`

### Debug Mode
```bash
# Enable verbose logging
export PODMAN_LOG_LEVEL=debug

# Check crun wrapper logs
tail -f /tmp/crun-debug.log

# Monitor systemd services
journalctl --user -f -u kinc-*
```

## Contributing

kinc is designed for extensibility:
- **CNI Plugins**: Add custom networking solutions
- **Storage Providers**: Integrate additional storage backends  
- **Monitoring**: Extend observability capabilities
- **Multi-Architecture**: Support ARM64 and other platforms

## License

THE SOFTWARE IS AI GENERATED AND PROVIDED “AS IS”, WITHOUT CLAIM OF COPYRIGHT OR WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

---

**kinc** - Kubernetes simplified, containerized, and democratized for rootless environments.
