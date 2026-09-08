# kinc - Kubernetes in Container

**Single-node rootless Kubernetes cluster running in a Podman container.**

[![Build Status](https://github.com/T0MASD/kinc/actions/workflows/ci.yml/badge.svg)](https://github.com/T0MASD/kinc/actions/workflows/ci.yml)
[![Release](https://github.com/T0MASD/kinc/actions/workflows/release.yml/badge.svg)](https://github.com/T0MASD/kinc/actions/workflows/release.yml)

---

## Features

- 🚀 **Fast:** Cluster ready in ~40 seconds (with cached images)
- 🔒 **Rootless:** Runs as regular user, no root required
- 📦 **Self-contained:** Everything in one container (systemd, CRI-O, kubeadm, kubectl)
- 🔧 **Configurable:** Baked-in or mounted configuration
- 🌐 **Isolated networking:** Sequential port allocation with subnet derivation
- 📊 **Multi-cluster:** Run multiple clusters concurrently
- ✅ **Production-grade:** Uses official Kubernetes tools (kubeadm, kubectl, CRI-O)

---

## Quick Start

### Prerequisites

- **Podman** (rootless)
- **IP forwarding enabled**
- **Sufficient inotify limits** (for multiple clusters)

```bash
# Enable IP forwarding (one-time setup)
sudo sysctl -w net.ipv4.ip_forward=1

# Make permanent
echo 'net.ipv4.ip_forward = 1' | sudo tee -a /etc/sysctl.d/99-kubernetes.conf
sudo sysctl -p /etc/sysctl.d/99-kubernetes.conf

# Increase inotify limits for multiple clusters
sudo sysctl -w fs.inotify.max_user_watches=524288
sudo sysctl -w fs.inotify.max_user_instances=512
```

### Deploy a Cluster

```bash
# Build the image (one time)
./tools/build.sh

# Deploy with baked-in config (simplest)
USE_BAKED_IN_CONFIG=true ./tools/deploy.sh

# Extract kubeconfig
mkdir -p ~/.kube
podman cp kinc-default-control-plane:/etc/kubernetes/admin.conf ~/.kube/config
sed -i 's|server: https://.*:6443|server: https://127.0.0.1:6443|g' ~/.kube/config

# Use your cluster
kubectl get nodes
kubectl get pods -A
```

### Deploy Multiple Clusters

```bash
# Deploy with mounted config (supports multiple clusters)
CLUSTER_NAME=dev ./tools/deploy.sh
CLUSTER_NAME=staging ./tools/deploy.sh
CLUSTER_NAME=prod ./tools/deploy.sh

# Clusters get sequential ports and isolated networks:
# dev:     127.0.0.1:6443, subnet 10.244.43.0/24
# staging: 127.0.0.1:6444, subnet 10.244.44.0/24
# prod:    127.0.0.1:6445, subnet 10.244.45.0/24
```

### Cleanup

```bash
# Remove a cluster
CLUSTER_NAME=default ./tools/cleanup.sh

# Or with baked-in config
USE_BAKED_IN_CONFIG=true CLUSTER_NAME=default ./tools/cleanup.sh
```

---

## Architecture

### Multi-Service Initialization

kinc uses a systemd-driven multi-service architecture for reliable initialization:

```
Container Start
    ↓
┌─────────────────────────────────────┐
│ kinc-preflight.service (oneshot)    │
│ - Config validation (yq)            │
│ - CRI-O readiness check             │
│ - kubeadm.conf templating           │
└─────────────────────────────────────┘
    ↓
┌─────────────────────────────────────┐
│ kubeadm-init.service (oneshot)      │
│ - kubeadm init (isolated)           │
│ - No kubectl waits                  │
│ - Clean systemd logs                │
└─────────────────────────────────────┘
    ↓
┌─────────────────────────────────────┐
│ kinc-postinit.service (oneshot)     │
│ - CNI installation (kindnet)        │
│ - Storage provisioner               │
│ - kubectl wait for readiness        │
└─────────────────────────────────────┘
    ↓
Initialization Complete
Marker: /var/lib/kinc-initialized
```

### Port and Network Allocation

Ports are allocated sequentially, and network subnets are derived from the port's last 2 digits:

| Cluster | Host Port     | Pod Subnet       | Service Subnet |
|---------|---------------|------------------|----------------|
| default | 127.0.0.1:6443 | 10.244.43.0/24   | 10.43.0.0/16   |
| cluster01 | 127.0.0.1:6444 | 10.244.44.0/24   | 10.44.0.0/16   |
| cluster02 | 127.0.0.1:6445 | 10.244.45.0/24   | 10.45.0.0/16   |

This ensures **non-overlapping networks** for concurrent clusters.

---

## Configuration Modes

### Baked-In Config (Zero-Config)

Use the default configuration embedded in the image:

```bash
USE_BAKED_IN_CONFIG=true ./tools/deploy.sh
```

- No config volume mount
- Single cluster only (can't customize cluster name in kubeadm.conf)
- Fastest deployment

### Mounted Config (Multi-Cluster)

Mount custom configuration from `runtime/config/kubeadm.conf`:

```bash
CLUSTER_NAME=myapp ./tools/deploy.sh
```

- Config volume mounted to `/etc/kinc/config`
- Supports multiple clusters with different names
- Per-cluster network isolation

---

## Tools

### `build.sh`
Build the kinc container image.

```bash
./tools/build.sh

# Force package updates
CACHE_BUST=1 ./tools/build.sh
```

### `deploy.sh`
Deploy a single kinc cluster using Quadlet (systemd integration).

```bash
# Baked-in config
USE_BAKED_IN_CONFIG=true ./tools/deploy.sh

# Mounted config with custom name
CLUSTER_NAME=myapp ./tools/deploy.sh

# Force specific port
FORCE_PORT=6500 CLUSTER_NAME=special ./tools/deploy.sh
```

**Features:**
- System prerequisites validation (IP forwarding, inotify limits)
- Automatic sequential port allocation
- Subnet derivation from port
- Systemd-driven initialization waits
- Multi-service architecture verification

### `cleanup.sh`
Remove a kinc cluster and clean up all resources.

```bash
CLUSTER_NAME=myapp ./tools/cleanup.sh
```

**What it does:**
- Stops systemd services
- Removes container
- Removes volumes
- Removes Quadlet files
- Reloads systemd

### `run-validation.sh`
Run full validation suite (7 clusters):

```bash
./tools/run-validation.sh

# Skip cleanup for manual inspection
SKIP_CLEANUP=true ./tools/run-validation.sh
```

**Tests:**
- T1: Baked-in config (deploy.sh)
- T2: Mounted config - 5 concurrent clusters (deploy.sh)
- T3: Direct podman run (baked-in config)
- Multi-service architecture verification
- Complete cleanup

---

## Advanced Usage

### Direct Podman Run (No Quadlet)

For environments without systemd or for quick testing:

```bash
# Create volume
podman volume create kinc-var-data

# Run cluster
podman run -d --name kinc-cluster \
  --hostname kinc-control-plane \
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
  --volume kinc-var-data:/var:rw \
  --volume $HOME/.local/share/containers/storage:/root/.local/share/containers/storage:rw \
  --sysctl net.ipv6.conf.all.disable_ipv6=0 \
  --sysctl net.ipv6.conf.all.keep_addr_on_down=1 \
  --sysctl net.netfilter.nf_conntrack_tcp_timeout_established=86400 \
  --sysctl net.netfilter.nf_conntrack_tcp_timeout_close_wait=3600 \
  -p 127.0.0.1:6443:6443/tcp \
  --env container=podman \
  ghcr.io/t0masd/kinc:latest

# Wait for cluster (~40 seconds)
timeout 300 bash -c 'until podman exec kinc-cluster test -f /var/lib/kinc-initialized 2>/dev/null; do sleep 2; done'

# Extract kubeconfig
mkdir -p ~/.kube
podman cp kinc-cluster:/etc/kubernetes/admin.conf ~/.kube/config
sed -i 's|server: https://.*:6443|server: https://127.0.0.1:6443|g' ~/.kube/config

# Verify
kubectl get nodes
```

### Custom kubeadm Configuration

Edit `runtime/config/kubeadm.conf` to customize:
- Kubernetes version
- Pod/Service subnets
- API server arguments
- Kubelet configuration
- Feature gates

Then deploy with mounted config:

```bash
CLUSTER_NAME=custom ./tools/deploy.sh
```

---

## Troubleshooting

### Check Initialization Status

```bash
# View multi-service status
podman exec kinc-default-control-plane systemctl status \
  kinc-preflight.service \
  kubeadm-init.service \
  kinc-postinit.service

# Check initialization marker
podman exec kinc-default-control-plane test -f /var/lib/kinc-initialized && echo "✅ Initialized" || echo "❌ Not initialized"
```

### View Logs

```bash
# Preflight logs (config validation, CRI-O check)
podman exec kinc-default-control-plane journalctl -u kinc-preflight.service

# kubeadm init logs
podman exec kinc-default-control-plane journalctl -u kubeadm-init.service

# Postinit logs (CNI, storage, waits)
podman exec kinc-default-control-plane journalctl -u kinc-postinit.service

# CRI-O logs
podman exec kinc-default-control-plane journalctl -u crio.service

# Kubelet logs
podman exec kinc-default-control-plane journalctl -u kubelet.service
```

### Common Issues

**Port already in use:**
```bash
# Check what's using the port
podman ps --filter "name=kinc" --format "table {{.Names}}\t{{.Ports}}"

# Use a different cluster name or force a different port
FORCE_PORT=6500 CLUSTER_NAME=myapp ./tools/deploy.sh
```

**IP forwarding disabled:**
```bash
# Check status
cat /proc/sys/net/ipv4/ip_forward

# Enable
sudo sysctl -w net.ipv4.ip_forward=1
```

**Too many open files (multiple clusters):**
```bash
# Increase inotify limits
sudo sysctl -w fs.inotify.max_user_watches=524288
sudo sysctl -w fs.inotify.max_user_instances=512
```

---

## System Requirements

### Minimum
- **CPU:** 2 cores
- **RAM:** 2GB per cluster
- **Disk:** 5GB per cluster
- **Podman:** 4.0+
- **Kernel:** 5.10+ (user namespaces, cgroups v2)

### Recommended for Multiple Clusters
- **CPU:** 4+ cores
- **RAM:** 4GB+ (2GB per cluster)
- **Inotify limits:** 524288 watches, 512 instances

---

## Components

- **Kubernetes:** v1.33.5
- **CRI-O:** v1.33.5
- **kubeadm:** v1.33.5
- **kubectl:** v1.33.5
- **CNI:** kindnet (from Kubernetes KIND project)
- **Storage:** local-path-provisioner
- **Base:** Fedora 42

---

## Development

### Build from Source

```bash
# Build image
./tools/build.sh

# Deploy for testing
USE_BAKED_IN_CONFIG=true ./tools/deploy.sh

# Run full validation suite
./tools/run-validation.sh
```

### CI/CD

kinc uses GitHub Actions:
- **ci.yml:** Builds, deploys, and validates on every push
- **release.yml:** Builds and publishes images on tags

---

## License

THE SOFTWARE IS AI GENERATED AND PROVIDED “AS IS”, WITHOUT CLAIM OF COPYRIGHT OR WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

---

## Credits

- **KIND (Kubernetes IN Docker):** Inspiration and kindnet CNI
- **kubeadm:** Cluster bootstrapping
- **CRI-O:** Container runtime
- **Podman:** Rootless containers
- **systemd:** Service management

