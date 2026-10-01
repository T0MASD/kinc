# kinc - Kubernetes in Container

**Rootless Kubernetes cluster running in Podman containers, one per node.**

[![Build Status](https://github.com/T0MASD/kinc/actions/workflows/ci.yml/badge.svg)](https://github.com/T0MASD/kinc/actions/workflows/ci.yml)
[![Release](https://github.com/T0MASD/kinc/actions/workflows/release.yml/badge.svg)](https://github.com/T0MASD/kinc/actions/workflows/release.yml)
[![License](https://img.shields.io/badge/License-Unlicense-blue.svg)](https://raw.githubusercontent.com/T0MASD/faro/refs/heads/main/UNLICENSE)

---

## Features

- 🚀 **Fast:** Cluster ready in ~40 seconds (with cached images)
- 🔒 **Rootless:** Runs as regular user, no root required
- 📦 **Self-contained:** Each node is one container (systemd, CRI-O, kubeadm, kubectl)
- 🔧 **Configurable:** Baked-in or mounted configuration
- 🌐 **Isolated networking:** Sequential port allocation with subnet derivation
- 🧩 **Multi-node:** A cluster has as many nodes as you ask for, on one host
- 📊 **Multi-cluster:** Run multiple clusters concurrently
- 🔍 **Observability:** Optional Faro event capture for what changed, and API-server audit for what was read and deleted (both enabled in CI)
- ✅ **Production-grade:** Uses official Kubernetes tools (kubeadm, kubectl, CRI-O)

---

## Quick Start

### Prerequisites

- **Podman** (rootless)
- **IP forwarding enabled**
- **Sufficient inotify limits** (for multiple clusters)
- **Sufficient kernel keyring limits** (for multiple clusters)
- **User namespaces available to Podman** (AppArmor hosts)
- **`openvswitch` and `geneve` kernel modules loaded** (Antrea's datapath)

`deploy.sh` reports which kernel mandatory access control system is active and
adapts to it. Under SELinux it restores the context on the config volume, which
a rootless user can do to files they own. Under AppArmor it asks Podman to
create a user namespace, since that is what rootless Podman needs to start the
cluster container.

Ubuntu 24.04 and later set `kernel.apparmor_restrict_unprivileged_userns` to 1
and ship a profile granting Podman `userns create`, so the probe passes with the
restriction in place. Where it does not pass, lifting the restriction takes root
and so belongs with the sysctls below:

```bash
# Only where deploy.sh reports Podman cannot create a user namespace
sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
echo 'kernel.apparmor_restrict_unprivileged_userns = 0' | sudo tee -a /etc/sysctl.d/99-kubernetes.conf
```

Antrea's datapath is Open vSwitch, and geneve encapsulates traffic between
nodes. A rootless nested container cannot load a kernel module itself, so the
host loads them:

```bash
sudo modprobe openvswitch geneve

# Make permanent
printf 'openvswitch\ngeneve\n' | sudo tee /etc/modules-load.d/kinc.conf
```

```bash
# Enable IP forwarding (one-time setup)
sudo sysctl -w net.ipv4.ip_forward=1

# Make permanent
echo 'net.ipv4.ip_forward = 1' | sudo tee -a /etc/sysctl.d/99-kubernetes.conf
sudo sysctl -p /etc/sysctl.d/99-kubernetes.conf

# Increase inotify limits for multiple clusters
sudo sysctl -w fs.inotify.max_user_watches=524288
sudo sysctl -w fs.inotify.max_user_instances=2048

# Increase kernel keyring limits (critical for multi-cluster)
sudo sysctl -w kernel.keys.maxkeys=1000
sudo sysctl -w kernel.keys.maxbytes=25000

# Make all changes persistent
echo 'fs.inotify.max_user_watches = 524288' | sudo tee -a /etc/sysctl.d/99-kubernetes.conf
echo 'fs.inotify.max_user_instances = 2048' | sudo tee -a /etc/sysctl.d/99-kubernetes.conf
echo 'kernel.keys.maxkeys = 1000' | sudo tee -a /etc/sysctl.d/99-kubernetes.conf
echo 'kernel.keys.maxbytes = 25000' | sudo tee -a /etc/sysctl.d/99-kubernetes.conf
sudo sysctl -p /etc/sysctl.d/99-kubernetes.conf
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

### Deploy Multiple Nodes

```bash
# A control plane and two workers, each its own container
KINC_WORKERS=2 ./tools/deploy.sh
```

Each worker joins with a config that is complete before it starts: the cluster
CA is minted first, so every join states the hash it pins rather than learning
it from the control plane. A worker publishes no ports - it is reached over the
cluster's own podman network, which is also how it resolves the control plane
by name. Pod traffic between nodes travels Antrea's geneve tunnel, which is
what the `openvswitch` and `geneve` modules are required for.

`KINC_WORKERS` defaults to 0, which is a single-node cluster.

### Deploy Multiple Clusters

```bash
# Deploy with mounted config (supports multiple clusters)
CLUSTER_NAME=dev ./tools/deploy.sh
CLUSTER_NAME=staging ./tools/deploy.sh
CLUSTER_NAME=prod ./tools/deploy.sh

# Clusters get sequential ports and their own network and pod CIDR:
# dev:     127.0.0.1:6443, pods 10.244.0.0/21
# staging: 127.0.0.1:6444, pods 10.244.8.0/21
# prod:    127.0.0.1:6445, pods 10.244.16.0/21
```

A cluster's pod CIDR is a /21 because the controller-manager carves a /24 per
node out of it: eight nodes per cluster, and 32 clusters inside 10.244.0.0/16.
Clusters are isolated from each other - each has its own podman network, so
one cluster's nodes cannot see another's.

### Image Store

Each node has its own image store, at
`~/.local/share/kinc/<cluster>/stores/<node>`.

One per node, not one shared. `containers/storage` is single-writer: point two
CRI-O daemons at one directory and each garbage-collects the layers the other
still references, so the second node to start wins and the first is left
running containers whose lower layers are gone. It does not fail loudly —
lookups still resolve from cache while `readdir` returns nothing, so a
container reports an empty rootfs and a binary it shipped with becomes "no such
file or directory".

They are also separate from your podman store, for a different reason: mounting
that one made the cluster's runtime and your podman two writers of one store,
let the cluster run any image on the host without pulling, and left cluster
images where you prune for your own reasons.

The stores live under the cluster's state directory, so `cleanup.sh` removes
them with everything else. It does that through `podman unshare`, because layer
directories are owned by a mapped root and a plain `rm` stops at "Permission
denied":

```bash
# cleanup.sh does this for you; by hand it is
podman unshare rm -rf ~/.local/share/kinc/<cluster>
```

The cost is one pull per node rather than per cluster. kinc pulls the
control-plane images before `kubeadm init` rather than during it, so the pull
does not race kubeadm's deadline.

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
│ - Control-plane images pre-pulled   │
└─────────────────────────────────────┘
    ↓
┌─────────────────────────────────────┐
│ kubeadm-init.service (oneshot)      │
│ - kubeadm init phase by phase       │
│ - Scheduler started last            │
│ - Logs to a file, not the journal   │
└─────────────────────────────────────┘
    ↓
┌─────────────────────────────────────┐
│ kinc-postinit.service (oneshot)     │
│ - CNI installation (Antrea)         │
│ - Storage provisioner               │
│ - kubectl wait for readiness        │
└─────────────────────────────────────┘
    ↓
Initialization Complete
Marker: /var/lib/kinc-initialized
```

Not a plain `kubeadm init`. kinc drives the phases itself so it can hold the
scheduler back until `system:kube-scheduler`'s ClusterRoleBindings exist —
started with everything else, the scheduler comes up before kubeadm has created
them and is denied 52 times before they appear. The phase list is asserted at
build time against `kubeadm-phases.expected`, so a kubeadm release that adds or
removes a phase fails the build rather than producing a cluster that came up
subtly wrong.

Workers take a different path: `kubeadm-init.service` is replaced by a join
drop-in, so they run `kubeadm join` against the CA minted before any node
started.

### Port and Network Allocation

Ports are allocated sequentially, and network subnets are derived from the port's last 2 digits:

| Cluster   | Host Port      | Pod Subnet     | Service Subnet |
|-----------|----------------|----------------|----------------|
| default   | 127.0.0.1:6443 | 10.244.0.0/21  | 10.43.0.0/16   |
| cluster01 | 127.0.0.1:6444 | 10.244.8.0/21  | 10.44.0.0/16   |
| cluster02 | 127.0.0.1:6445 | 10.244.16.0/21 | 10.45.0.0/16   |

This ensures **non-overlapping networks** for concurrent clusters.

A pod subnet is a /21 because the controller-manager carves a /24 out of it per
node: eight nodes per cluster, and 32 clusters within 10.244.0.0/16. Each
cluster also gets its own podman network, so one cluster's nodes cannot reach
another's.

---

## Configuration Modes

### Baked-In Config (Zero-Config)

Use the default configuration embedded in the image:

```bash
USE_BAKED_IN_CONFIG=true ./tools/deploy.sh
```

- No config volume mount
- Single cluster only (can't customize cluster name in kubeadm.conf), though it can still have workers
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

# Bypass sysctl checks (not recommended)
KINC_SKIP_SYSCTL_CHECKS=true CLUSTER_NAME=myapp ./tools/deploy.sh
```

**Features:**
- System prerequisites validation (IP forwarding, inotify limits, kernel keyring)
- Smart multi-cluster detection: requires proper sysctls when other clusters exist
- Automatic sequential port allocation
- Subnet derivation from port
- Systemd-driven initialization waits
- Multi-service architecture verification

**Environment Variables:**
- `CLUSTER_NAME`: Cluster identifier (default: `default`)
- `FORCE_PORT`: Override auto port allocation
- `KINC_IMAGE`: Image to use (default: `localhost/kinc/node:v1.37.0`)
- `KINC_SKIP_SYSCTL_CHECKS`: Bypass inotify/keyring checks (default: `false`)
- `KINC_ENABLE_FARO`: Enable Faro event capture (default: `false`, CI: `true`)
- `KINC_AUDIT_RESOURCES`: Comma-separated `<group>/<resource>` to audit reads and deletes of (default: unset, no audit flags at all)
- `KINC_WORKERS`: Worker nodes to join (default: `0`, a single-node cluster)
- `KINC_NODE_MEMORY`, `KINC_NODE_CPUS`: what each node may use (default: unset, unlimited)
- `KINC_CLUSTER_MEMORY`, `KINC_CLUSTER_CPUS`: what the cluster may use in total (default: unset, unlimited)
- `KINC_NODE_RESERVED_MEMORY`, `KINC_NODE_RESERVED_CPU`: what a node keeps for itself rather than offering to the scheduler (default: `2Gi`/`500m` on a control plane, `1Gi`/`200m` on a worker)

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

For environments without systemd or for quick testing. This is a single-node
cluster: workers need a podman network and a join config, which `deploy.sh`
renders.

The host still needs what Antrea's datapath needs - `openvswitch` and `geneve`
loaded, and the volume's mount shared. `deploy.sh` checks both and says so;
here they are your responsibility.

Give the node its own image store rather than mounting your podman store into
it — see [Image Store](#image-store) for why that matters — and a volume for
PersistentVolumes, which are otherwise tmpfs-backed and lost on restart.

```bash
# Create volumes and this node's own image store
podman volume create kinc-var-data
podman volume create kinc-manual-storage
mkdir -p ~/.local/share/kinc/manual/stores/kinc-cluster

# Run cluster
podman run -d --name kinc-cluster \
  --hostname kinc-control-plane \
  --cgroups=split \
  --cap-add=all \
  --device /dev/fuse \
  --tmpfs /tmp:rw,rprivate,nosuid,nodev,tmpcopyup \
  --tmpfs /run:rw,rshared,nosuid,nodev,tmpcopyup \
  --tmpfs /run/lock:rw,rprivate,nosuid,nodev,tmpcopyup \
  --volume kinc-var-data:/var:rw,rslave \
  --volume /lib/modules:/lib/modules:ro \
  --volume $HOME/.local/share/kinc/manual/stores/kinc-cluster:/root/.local/share/containers/storage:rw \
  --volume kinc-manual-storage:/tmp/kinc-storage:rw \
  --sysctl net.ipv6.conf.all.disable_ipv6=0 \
  --sysctl net.ipv6.conf.all.keep_addr_on_down=1 \
  --sysctl net.netfilter.nf_conntrack_tcp_timeout_established=86400 \
  --sysctl net.netfilter.nf_conntrack_tcp_timeout_close_wait=3600 \
  -p 127.0.0.1:6443:6443/tcp \
  --env container=podman \
  localhost/kinc/node:v1.37.0

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

### API-Server Audit Logging (Optional)

**API-server audit** records what was read and what was deleted. Off unless
asked for, like Faro, and narrow on purpose: you name the resources.

**Enable audit:**

```bash
# Record the resources you name. Off unless set.
KINC_AUDIT_RESOURCES="/pods,fleet.example.com/widgets" ./tools/deploy.sh
```

Each entry is `<group>/<resource>`; the core group is empty, so `/pods`.

**Why both, and what each answers:**

Faro records what *changed* — it watches, so it sees creates, updates and
deletes as they happen. Audit answers the two questions a watch cannot:

- **Who read this?** A GET or LIST changes nothing, raises no watch event and
  is invisible to every informer. The audit log is the only place a read exists.
- **Who deleted this?** A watch says an object is gone, never who removed it,
  and the object is past tense by the time anything can ask.

Entries are `Metadata` level for `get`, `list`, `watch` and `delete` — user,
impersonated user, verb, objectRef, source IPs and timestamps, no bodies.
Everything else on the cluster is not logged, because auditing everything is a
volume problem and naming the resources is the point.

**Access audit events:**

```bash
# Inside the control-plane container, on the cluster's own volume
AUDIT_PATH="$HOME/.local/share/containers/storage/volumes/kinc-${CLUSTER_NAME}-var-data/_data/log/kubernetes/audit"

# Who read what
jq -r 'select(.verb=="get") | "\(.user.username) \(.objectRef.resource)"' $AUDIT_PATH/audit.log | sort | uniq -c | sort -rn

# Who deleted what
jq -r 'select(.verb=="delete") | "\(.requestReceivedTimestamp) \(.user.username) \(.objectRef.resource)/\(.objectRef.name)"' $AUDIT_PATH/audit.log
```

It survives a container restart and is capped at 100MB × 10 files × 30 days.
Unset, the API server starts with no audit flags at all and nothing is written.

### Node Resources (Optional)

Unset, a node may use the whole machine and says so. That is the default and it
is usually what you want on a workstation.

It is not what you want on a small VM. A node reports capacity by reading
`/proc`, which inside a container is the host's, so **every node of a cluster
reports the whole machine and the scheduler adds them up**. Measured on an
8-CPU 31G host, a two-node cluster advertised 16 CPU and 62Gi. On a 2 CPU / 4G
VM, two nodes each claim the whole VM.

```bash
KINC_NODE_MEMORY=2G KINC_NODE_CPUS=1 \
KINC_CLUSTER_MEMORY=4G KINC_CLUSTER_CPUS=2 \
KINC_WORKERS=1 ./tools/deploy.sh
```

Each node's systemd unit gets `MemoryHigh` and `CPUQuota`, and podman nests the
container's cgroup under it, so the limit covers the kubelet, CRI-O and every
pod on that node. `MemoryMax` is set 10% above as a backstop: memory pressure
throttles and reclaims before anything is killed. Each cluster also gets a
slice, so `systemd-cgls` shows a cluster as a cluster and the whole of one can
be bounded together.

The kubelet is told the same number, as `systemReserved`, so `allocatable`
becomes what the node may have while `capacity` still reports the machine. The
scheduler places against allocatable.

**A node keeps some of that for itself.** Measured idle on an empty cluster, a
control plane's cgroup held 2956MiB and a worker's 1231MiB — the control plane
carries etcd, the API server, the controller-manager and the scheduler as
static pods, and a static pod has no memory request, so nothing else accounts
for it. `KINC_NODE_RESERVED_MEMORY` and `KINC_NODE_RESERVED_CPU` default to
`2Gi`/`500m` on a control plane and `1Gi`/`200m` on a worker for that reason.

So a node needs to be larger than its reserve, and kinc refuses to start one
that is not. **On a 2 CPU / 4G VM a kinc control plane does not fit in 2G**: the
honest shapes are one node, or an asymmetric split such as 3G for the control
plane and 1G for a worker.

```bash
./tools/ci-verify-node-resources.sh default     # asked, enforced and advertised agree
```

Memory eviction is deliberately not configured. The kubelet derives
`memory.available` from the host as well — it reported 30.7Gi on a node limited
to 4G and using 1G — so a threshold would never fire. The cgroup does that job.

### Surviving a Restart

A node comes back as the same node. `/etc/kubernetes` is a named volume, so the
PKI, the kubeconfigs and the static pod manifests that are the control plane
outlive the container; and each node has a fixed address, because that address
is written into the API server's serving certificate, every kubeconfig and
`--advertise-address`.

This matters without anyone restarting anything on purpose: `Restart=always` is
in the quadlet, so a crash of the container's PID 1 is enough.

```bash
./tools/ci-verify-restart.sh default    # restarts every node, asserts it returns
```

### Faro Event Capture (Optional)

**Faro** is a Kubernetes resource monitoring library that captures real-time events during cluster bootstrap. It's useful for:
- Debugging initialization issues
- Performance analysis
- CI/CD validation
- Cluster behavior comparison

**Enable Faro:**

```bash
# Single cluster with event capture
KINC_ENABLE_FARO=true CLUSTER_NAME=myapp ./tools/deploy.sh

# Multiple clusters with event capture
KINC_ENABLE_FARO=true CLUSTER_NAME=dev ./tools/deploy.sh
KINC_ENABLE_FARO=true CLUSTER_NAME=staging ./tools/deploy.sh
```

**Default Behavior:**
- **Disabled** in normal deployments (minimal overhead)
- **Enabled** automatically in CI/CD (for validation)

**Configuration:**

Faro configuration and deployment are embedded in the kinc image:

- **Config:** `build/kinc/etc/faro/config.yaml` - Defines what resources to monitor
- **Deployment:** `build/kinc/etc/kubernetes/manifests/faro-bootstrap.yaml` - Static pod manifest

When `KINC_ENABLE_FARO=true`, the preflight service copies the Faro manifest to `/etc/kubernetes/manifests/` during initialization, and Kubelet starts it as a static pod alongside the API server.

**Access Faro Events:**

Events are stored in JSON format in the cluster's data volume:

```bash
# Direct access from host (no podman exec needed)
CLUSTER_NAME=myapp
FARO_PATH="$HOME/.local/share/containers/storage/volumes/kinc-${CLUSTER_NAME}-var-data/_data/lib/kinc/faro-events/logs"

# View events
cat $FARO_PATH/*.json | jq .

# Event summary
cat $FARO_PATH/*.json | jq -r '.gvr' | sort | uniq -c | sort -rn
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

Every kinc script writes a file under `/var/log/kinc/`, and that is the place
to look — `kubeadm-init` in particular writes only there, so `journalctl -u
kubeadm-init.service` shows two lines of systemd bookkeeping and nothing else.

```bash
# What the three init scripts said, in order
podman exec kinc-default-control-plane sh -c 'cat /var/log/kinc/kinc-preflight.log'
podman exec kinc-default-control-plane sh -c 'cat /var/log/kinc/kubeadm-init.log'
podman exec kinc-default-control-plane sh -c 'cat /var/log/kinc/kinc-postinit.log'
```

preflight and postinit also go to the journal; the runtime and the kubelet only
go there:

```bash
podman exec kinc-default-control-plane journalctl -u kinc-preflight.service
podman exec kinc-default-control-plane journalctl -u kinc-postinit.service
podman exec kinc-default-control-plane journalctl -u crio.service
podman exec kinc-default-control-plane journalctl -u kubelet.service

# Everything any unit logged above warning, in order
podman exec kinc-default-control-plane sh -c \
  'journalctl --no-pager --boot | grep -E " [EF][0-9]{4} "'
```

Pod logs are on the node's filesystem too, which is where to read them when the
API server is the thing that is broken:

```bash
podman exec kinc-default-control-plane sh -c 'ls /var/log/pods'
podman exec kinc-default-control-plane sh -c 'cat /var/log/pods/kube-system_etcd-*/etcd/*.log'
```

### Logs from a CI run

CI collects all of the above into artifacts on every run, passing or failing,
so a red build does not need reproducing to be read. From a run page, under
**Artifacts**:

| Artifact | Contains |
|---|---|
| `kinc-diagnostics-<job>-<n>` | Per node: `kubelet.log`, `crio.log`, full boot `journal.txt`, `errors.log` (every line above warning), `kinc-scripts.log` (all three `/var/log/kinc/*.log`), failed units, `inspect.json`. Plus every pod's log, Antrea's `agentinfo`/`podinterface`/`ovsflows`, cluster state, and the host contract kinc was given. |
| `audit-log-<job>-<n>` | The API-server audit log, if the cluster was deployed with `KINC_AUDIT_RESOURCES`. |
| `faro-events-<job>-<n>` | Faro's captured events, if deployed with `KINC_ENABLE_FARO=true`. |
| `run-summary-<job>-<n>` | Every error class in the run: how far into its component's life it last appeared, how often, how long since, and whether it is startup noise, a one-off, stopped or still going. |

The summary is also printed into the job log and the job summary, so it needs
no download to read.

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

**Deployment blocked due to sysctl limits:**

The deploy script will exit if attempting multi-cluster deployment with insufficient limits:
```bash
❌ CRITICAL: Multi-cluster deployment requires proper inotify limits
   Found 1 existing cluster(s)
```

**Fix:**
```bash
# Increase inotify and kernel keyring limits
sudo sysctl -w fs.inotify.max_user_watches=524288
sudo sysctl -w fs.inotify.max_user_instances=2048
sudo sysctl -w kernel.keys.maxkeys=1000
sudo sysctl -w kernel.keys.maxbytes=25000

# Make persistent
echo 'fs.inotify.max_user_watches = 524288' | sudo tee -a /etc/sysctl.d/99-kubernetes.conf
echo 'fs.inotify.max_user_instances = 2048' | sudo tee -a /etc/sysctl.d/99-kubernetes.conf
echo 'kernel.keys.maxkeys = 1000' | sudo tee -a /etc/sysctl.d/99-kubernetes.conf
echo 'kernel.keys.maxbytes = 25000' | sudo tee -a /etc/sysctl.d/99-kubernetes.conf
sudo sysctl -p /etc/sysctl.d/99-kubernetes.conf
```

**Or bypass (not recommended):**
```bash
KINC_SKIP_SYSCTL_CHECKS=true CLUSTER_NAME=cluster02 ./tools/deploy.sh
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
- **Inotify limits:** 524288 watches, 2048 instances
- **Kernel keyring limits:** 1000 maxkeys, 25000 maxbytes

---

## Components

- **Kubernetes:** v1.37.0
- **CRI-O:** v1.37.1
- **kubeadm:** v1.37.0
- **kubectl:** v1.37.0
- **CNI:** Antrea v2.7.0 (Open vSwitch datapath, geneve between nodes)
- **Storage:** local-path-provisioner
- **Base:** Fedora 44

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

- **Fedora:** The base image, and every package kinc runs — kubernetes, kubeadm,
  cri-tools and cri-o all come from Fedora's own builds rather than upstream
  binaries, which is what makes the image a normal `dnf install`
- **KIND (Kubernetes IN Docker):** Inspiration
- **Antrea:** Cluster networking
- **kubeadm:** Cluster bootstrap
- **CRI-O:** Container runtime
- **Podman:** Rootless containers
- **systemd:** Service management
- **local-path-provisioner:** Dynamic PersistentVolumes

