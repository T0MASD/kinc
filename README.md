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
- 🧩 **Multi-node:** A cluster has as many nodes as you ask for, on one host by default
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

kinc is consumed as a published image. `KINC_IMAGE` names which one, and
`deploy.sh` pulls it if it is not already local:

```bash
git clone https://github.com/T0MASD/kinc.git && cd kinc

export KINC_IMAGE=ghcr.io/t0masd/kinc:v1.37.0-3
USE_BAKED_IN_CONFIG=true ./tools/deploy.sh
```

Measured on a workstation: 134s from nothing including the image pull, 73s when
the image is already local, to a cluster whose addons have converged rather than
to a command that has returned. `deploy.sh` waits for CoreDNS to be available
before it says it is done.

Then take the kubeconfig. The port is allocated per cluster rather than fixed,
and `deploy.sh` prints which one it chose, so ask the cluster rather than
assuming 6443:

```bash
mkdir -p ~/.kube
PORT=$(podman inspect kinc-default-control-plane \
       --format '{{(index .NetworkSettings.Ports "6443/tcp" 0).HostPort}}')
podman cp kinc-default-control-plane:/etc/kubernetes/admin.conf ~/.kube/config
sed -i "s|server: https://.*:6443|server: https://127.0.0.1:${PORT}|g" ~/.kube/config

kubectl get nodes
kubectl get pods -A
```

Releases are at [github.com/T0MASD/kinc/releases](https://github.com/T0MASD/kinc/releases).
`./tools/build.sh` builds the image from this tree instead, which is what you
want when changing kinc itself; see [build.sh](#buildsh).

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

**Node addresses come from the cluster's podman network**, which is why a
cluster is one host by default: `advertiseAddress` and each node's `node-ip` are
set to an address on that network, and the network lives in a rootless namespace
that nothing outside can route to.

What does **not** open that up is exposing the subnet. netavark's chain for the
network ends with:

```
ip daddr 10.89.43.0/24 accept
ip daddr != 224.0.0.0/4 masquerade
```

Addresses are left alone within the node subnet and rewritten for anything
leaving it, so a node's address stops being its own at the boundary and replies
have nowhere to go. The problem is not reachability, and routing the subnet out
does not solve it.

The symptom is worth knowing because it points away from the cause. A node
reached that way registers and goes **Ready, and stays Ready** - its own traffic
is outbound, and outbound works. The failure appears only when the API server
dials back into the kubelet, so `kubectl logs`, `exec`, `port-forward` and
metrics fail against a node every other indicator calls healthy, and it flaps
with whichever side restarted last.

If you try it regardless: an exemption has to go at the top of netavark's own
chain, because a verdict reached in a different chain does not pre-empt it, and
it has to be re-asserted, because netavark rewrites its ruleset whenever a
container changes.

**Spanning hosts is a different change, and nothing here forbids it.** The
addresses are the constraint, not the architecture. A node on another host would
need to register under an address routable between the hosts rather than one from
the podman network, and the ports Kubernetes uses between nodes would need
publishing the way the API server's 6443 already is - the kubelet on 10250 so the
API server can dial back, and Antrea's geneve on UDP 6081 so pod traffic can
cross. That is the same mechanism the control plane already uses to be reachable,
rather than an attempt to make the namespace routable.

kinc does not do this today and it is not tested here. It is a design worth
knowing is available, not a configuration you can switch on.

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

### Container Creation and OOM Scores

CRI-O's runtime is a wrapper. `/usr/bin/crun` is a symlink to
`/usr/local/bin/crun-wrapper.sh`, and crun itself is `/usr/bin/crun.orig`. The
wrapper edits one field of the OCI spec and then execs the real crun.

The field is `process.oomScoreAdj`, and the reason is that a rootless process
cannot lower `oom_score_adj` below the floor its session inherited. The kernel
checks `CAP_SYS_RESOURCE` against the initial user namespace, so no capability a
rootless container can hold satisfies it. crun treats the refusal as fatal
rather than advisory:

```
Container creation error: write to `/proc/self/oom_score_adj`: Permission denied
```

The kubelet asks for -997 on Guaranteed pods and -999 on the control plane's
static pods, so the wrapper is what lets the API server start at all. Removing
it is enough to stop a cluster coming up: etcd, kube-apiserver and
kube-controller-manager all fail to create, and kubeadm waits for an API server
that never arrives.

**It removes the value only when the value cannot be set.** Lowering below the
inherited floor is what needs the capability; raising above it always succeeds,
so anything at or above the floor is passed through untouched. That distinction
is what keeps the cluster's OOM ordering, because the kubelet uses the positive
end of the range deliberately: 997, 998 and 1000 on Burstable and BestEffort
pods, precisely so they are chosen first.

Measured on a default two-node cluster, where the inherited floor is 200:

| `oom_score_adj` | Processes |
|---|---|
| 200 | The control plane, the kubelet, CRI-O, antrea-agent, and everything else that asked for a negative value |
| 997 | antrea-controller |
| 998 | coredns |
| 1000 | local-path-provisioner |

So the ordering a cluster depends on holds: under memory pressure the kernel
takes ordinary pods before it takes the control plane. What differs from a
root-run cluster is the distance. The control plane sits at the floor rather
than at -999, which separates it from the pods above it but not from anything
else on the host at the same floor. `KINC_NODE_MEMORY` is what bounds a node
against the rest of the machine; see
[Node Resources](#node-resources-optional).

Every invocation is recorded in `/var/log/crun-wrapper.log` on each node: what
CRI-O asked for, and what was done to the spec. It is the only account of a step
that happens between the kubelet's intent and the container that results. It
lives on the node's volume so it survives the restart that `kinc node` performs,
is rotated once at 16MiB and keeps one previous file, and
`ci-collect-diagnostics.sh` copies it into the per-node diagnostics of every CI
run. A rewrite that fails also goes to the journal under the `crun-wrapper` tag,
because the alternative is silence followed by a container that will not create.

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

**A control plane needs a larger share than a worker.** It carries the cluster,
and that burden comes out of allocatable rather than out of the reserve, so
kinc's defaults do not express it: they encode the asymmetry only as 2Gi/500m
reserved on a control plane against 1Gi/200m on a worker.

Measured on an idle cluster, the control-plane-specific load is its four static
pods:

| | CPU request | Memory request |
|---|---|---|
| kube-apiserver | 250m | none |
| kube-controller-manager | 200m | none |
| etcd | 100m | 100Mi |
| kube-scheduler | 100m | none |
| **Only on a control plane** | **650m** | **100Mi** |

Everything else a node runs, antrea-agent at 400m among it, runs on both. So a
control plane needs about 650m of CPU more than a worker before anything is
scheduled, and roughly 100Mi more memory.

**Reserve memory, size CPU.** Three of those four carry no memory request at
all, so nothing accounts for them and the reserve has to. Every one of them
carries a CPU request, which the scheduler can already see, so CPU needs no
equivalent reserve - it needs a larger share. That is why the memory reserve
differs by 1Gi between the roles while the CPU reserve differs by only 300m.

Splitting a machine evenly therefore runs a control plane far closer to its
ceiling than the number suggests. Measured on a 4 CPU / 8G VM at 2 CPU per node:
the control plane advertised 1500m and 1450m of it was committed, so a single
pod carrying a CPU request would not have scheduled there, while the worker sat
at 72%. The same cluster unlimited reported 36% of 4 CPU, which is the same
fact with nothing to measure it against.

Weight the split rather than dividing evenly. `KINC_NODE_*` applies to every
node; the per-role variables override it:

```bash
KINC_CONTROL_PLANE_MEMORY=5G KINC_CONTROL_PLANE_CPUS=3 \
KINC_WORKER_MEMORY=3G        KINC_WORKER_CPUS=1.5 \
KINC_WORKERS=1 ./tools/deploy.sh
```

Which gives, enforced and advertised:

```
kinc-default-control-plane   MemoryHigh=5G   CPUQuota=300%    2500m / 3Gi
kinc-default-w1              MemoryHigh=3G   CPUQuota=150%    1300m / 2Gi
```

**Changing a limit on a cluster that already exists.** The reservations are
rendered into the kubelet's config directory on every boot, so a node adopts
what it is given when it next starts. `deploy.sh` declines to re-render a
running cluster, so stop its units first and let the volumes stand:

```bash
systemctl --user stop kinc-default-control-plane.service kinc-default-w1.service
KINC_NODE_MEMORY=5G ./tools/deploy.sh      # same volumes, same PKI, same cluster
```

The cluster resumes rather than rebuilding: `/var/lib/kubeadm-initialized` is on
a volume, so `kubeadm init` is skipped and the node comes back as the same node
with the new figure in effect.

**What the kubelet enforces, and what it does not.** On a rootless node the
kubelet logs this once per start, and a `FailedNodeAllocatableEnforcement` event
goes with it:

```
Failed to update Node Allocatable Limits ["kubepods"]:
openat2 /sys/fs/cgroup/kubepods/cpuset.cpus: no such file or directory
```

The controllers delegated to a rootless user manager are `cpu memory pids`, and
`cpuset` is not among them, so the kubelet cannot write the part of its
enforcement that needs one. What it does write holds: measured with a 5G node
limit, `kubepods/memory.max` is the node's allocatable memory exactly, and
`kubepods/cpu.max` is unset. So the collective ceiling exists for memory, the
uncompressible one, and CPU is bounded by the node unit's `CPUQuota` instead.

Delegating `cpuset` is a host-side property of `user@.service`; a container
cannot grant itself a controller.


Memory eviction is deliberately not configured, because a threshold would
measure the host rather than the node. The kubelet computes `memory.available`
as the machine's capacity minus this node's working set, and inside a container
that capacity is the host's — so it accounts for neither the node's cgroup
limit nor any other node's usage.

How wrong that is depends on the host. On a workstation, a node limited to 4G
and nearly full still reported 30Gi available, so no threshold would fire. On a
small dedicated VM, where one node is most of the host, it approximates real
pressure — still over-reporting by whatever the other nodes use. The cgroup
does the bounding instead, reclaiming at `MemoryHigh` before killing at
`MemoryMax`; if you run a single node on a dedicated VM, adding a threshold is
reasonable as long as you know it tracks the VM.

### Surviving a Restart

A node comes back as the same node. `/etc/kubernetes` is a named volume, so the
PKI, the kubeconfigs and the static pod manifests that are the control plane
outlive the container; and each node has a fixed address, because that address
is written into the API server's serving certificate, every kubeconfig and
`--advertise-address`.

This matters without anyone restarting anything on purpose: `Restart=always` is
in the quadlet, so a crash of the container's PID 1 is enough.

A node also comes back bounded as it was. `MemoryHigh` and `CPUQuota` live on
the node's systemd unit, and the aggregate ones on the cluster's slice; both
outlive the container they bound.

A node also comes back at the configuration of the image it is now running,
which matters where a restart crosses an image change: the node binaries and
everything derived from them are the new image's, while the cluster's identity
and contents are the ones it was built with. Provisioning that reads the
environment or the image runs on every boot for that reason, and what is
genuinely once per cluster - `kubeadm init`, the CA, etcd - stays once.

```bash
./tools/ci-verify-restart.sh default    # restarts every node, asserts it returns

# The resource gate compares against what was asked for, so give it the same
# variables the cluster was deployed with.
KINC_NODE_MEMORY=2G KINC_NODE_CPUS=1 \
  ./tools/ci-verify-node-resources.sh default
```

### Faro Event Capture (Optional)

**Faro** is a Kubernetes resource monitoring library. kinc runs it as a **static
pod**, which is a bootstrap instrument: the kubelet starts it from a manifest on
disk, so it is watching from the moment the API server answers — before the
scheduler exists, before RBAC bootstrap has run, and before anything could be
deployed into the cluster. That window is what it is for:

- Debugging initialization issues
- Performance analysis
- CI/CD validation
- Cluster behavior comparison

Being a static pod is what that costs. It authenticates with a kubeconfig staged
on the node's filesystem rather than a ServiceAccount, because no ServiceAccount
exists yet; it writes to a hostPath, because there is no storage class yet; and
it runs with `hostNetwork`, because there is no CNI yet. Those are the right
trade-offs for capturing a bootstrap and the wrong ones for anything else.

Faro is its own project, not a kinc component. kinc embeds this one manifest so
that its own bootstrap can be analysed — the captures in CI, and the release
run's event counts, come from it. Running Faro against a cluster for any other
purpose is a question for Faro, which is packaged as an operator and deploys
like any other workload; nothing here is the recommended way to do that.

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

### How a run is verified

A run has three phases, and which one a check belongs to follows from what it
reads.

| Phase | What runs |
|---|---|
| Live | What needs a running cluster: initialization, the Antrea datapath, cross-node traffic, Faro, node resources, restart. |
| Capture | `ci-collect-diagnostics.sh`, `ci-collect-faro.sh` and `ci-collect-audit.sh` write the record; `cleanup.sh` then tears the cluster down. |
| Analyse | `ci-analyse-capture.sh` runs everything that reads that record: whether every component settled, whether any denial persisted, whether anything logged a deprecation, and the run summary. |

The analysis phase reads a finished record by design. Whether something has
stopped is silence measured against the end of the log, and the end of a log
holds still only once the cluster has. The phase also reaches what the job's
console does not: a component's own log lives in the capture, so a deprecation
the kubelet printed on every node is found there.

Every check in the phase runs even when an earlier one fails, and the phase
fails at the end if any did.

```bash
./tools/ci-analyse-capture.sh default                      # the whole phase
KINC_LOG_CAPTURE=<dir> ./tools/ci-verify-deprecations.sh   # one check, any archived capture
```

### Reading a node you cannot reach

A kinc node is a container, so `podman exec` reaches it on the host that runs
it. Where that host is not yours to log into - a node inside a VM whose only
interface is the API server - the cluster itself is the way in. A pod with
`hostPID: true` shares the node container's PID namespace, and PID 1 there is
the node's systemd:

```bash
kubectl run nodeenv --image=busybox --restart=Never --rm -it \
  --overrides='{"spec":{"hostPID":true,"nodeName":"kinc-default-control-plane",
                "containers":[{"name":"n","image":"busybox","securityContext":{"privileged":true},
                "command":["sh","-c","tr \\0 \\n < /proc/1/environ"],
                "stdin":true,"tty":true}]}}'
```

Which answers the question that matters when a node is configured by its
environment: whether the variable arrived. `KINC_NODE_MEMORY`,
`KINC_NODE_RESERVED_MEMORY` and the rest are set on the container by whatever
renders the quadlet, and a unit sees them only if it also declares
`PassEnvironment=` - so a value can be correct in the quadlet and absent from
the unit, and the node simply uses its default. Reading PID 1's environment
tells you which of the two halves to look at.

What the node then resolved is in
`/etc/kubernetes/kubelet.conf.d/20-kinc-node-resources.conf`, which is the file
the kubelet reads, and `kinc-node-resources.service` logs the arithmetic it did
to get there.

### Logs from a CI run

CI collects all of the above into artifacts on every run, passing or failing,
so a red build does not need reproducing to be read. From a run page, under
**Artifacts**:

| Artifact | Contains |
|---|---|
| `kinc-diagnostics-<job>-<n>` | Per node: `kubelet.log`, `crio.log`, full boot `journal.txt`, `errors.log` (every line above warning), `kinc-scripts.log` (all three `/var/log/kinc/*.log`), failed units, `inspect.json`. Plus every pod's log, Antrea's `agentinfo`/`podinterface`/`ovsflows`, cluster state, and the host contract kinc was given. |
| `audit-log-<job>-<n>` | The API-server audit log, if the cluster was deployed with `KINC_AUDIT_RESOURCES`. |
| `faro-events-<job>-<n>` | Faro's captured events, if deployed with `KINC_ENABLE_FARO=true`. |
| `run-summary-<job>-<n>` | Every error class in the run: how far into its component's life it last appeared, how often, how long since, and whether it is startup noise, a one-off, stopped or still going. Plus `deprecations-<cluster>.txt`, every deprecation any component logged, and for each one whether it is a finding or a known entry on the allowlist. |

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

kinc's own work is dedicated to the public domain; see [UNLICENSE](UNLICENSE).
That cannot cover third-party work kinc includes or derives from, which stays
under its own licence — see [NOTICE](NOTICE) for what and from where.

THE SOFTWARE IS AI GENERATED AND PROVIDED “AS IS”, WITHOUT CLAIM OF COPYRIGHT OR WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

---

## Credits

- **Fedora:** The base image, and every package kinc runs — kubernetes, kubeadm,
  cri-tools and cri-o all come from Fedora's own builds rather than upstream
  binaries, which is what makes the image a normal `dnf install`
- **KIND (Kubernetes IN Docker):** `build/Containerfile` is derived from kind's
  node base image — the configuration that lets systemd run as PID 1 in a
  container came from there. Apache-2.0; see [NOTICE](NOTICE)
- **Antrea:** Cluster networking
- **kubeadm:** Cluster bootstrap
- **CRI-O:** Container runtime
- **Podman:** Rootless containers
- **systemd:** Service management
- **local-path-provisioner:** Dynamic PersistentVolumes; its manifests are vendored here. Apache-2.0

