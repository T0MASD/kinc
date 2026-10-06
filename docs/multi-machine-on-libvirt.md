# One cluster across three machines, two transports

A worked case: a six-node Kubernetes cluster grown one node at a time across
three physical machines, where four nodes reach each other over plain routed
networking and two reach them through an encrypted tunnel, and where the
control plane can be replaced without the cluster noticing.

Everything below was built and measured on 2026-10-02. The timings, console
output and failures are from that run. Where a measurement turned out not to
mean what it appeared to mean, the correction is in the text — those are the
parts worth reading twice.

## The machines

| | study-pc | oras | ugnis |
|---|---|---|---|
| role | hypervisor | hypervisor | hypervisor |
| link | gigabit LAN, same rack | gigabit LAN, same rack | **wifi, elsewhere, behind NAT** |
| transport | routed veth | routed veth | **WireGuard** |

That asymmetry is the point. Two of the machines are a rack apart on a wire;
the third is on wifi in another place. A cluster should not have to pick one
transport for all of its nodes.

## The cluster it grew into

| node | machine | transport | node address |
|---|---|---|---|
| `kinc-dns-control-plane` | study-pc VM | routed veth | `10.89.43.2` |
| `kinc-dns-w1` | study-pc VM | routed veth | `10.89.43.3` |
| `kinc-dns-cp2` | oras VM 1 | routed veth | `10.89.21.3` |
| `kinc-dns-w2` | oras VM 1 | routed veth | `10.89.21.2` |
| `kinc-dns-cp3` | **ugnis VM** | **WireGuard** | **`10.99.0.3`** |
| `kinc-dns-w3` | **ugnis VM** | **WireGuard** | **`10.99.0.4`** |

One control plane per machine, so no single machine holds a quorum. Two of the
node addresses are WireGuard addresses and four are podman addresses. To the
cluster they are the same kind of thing.

---

## Why there are three network layers

kinc nodes are rootless podman containers, and rootless podman puts its network
in a user namespace of its own. Every machine's podman allocates from the same
range, so two machines hand their containers **identical addresses** — both
`10.89.x.2` — and neither can reach the other's.

Bridging the hypervisors does not fix this. The namespace is the boundary, not
the LAN. Worth stating plainly, because bridging is the first thing to reach
for and it produces a setup that looks right and does not work.

| layer | carries | why |
|---|---|---|
| libvirt `default` (NAT) | management, **DNS** | each VM's resolver, and where the control-plane name lives |
| VXLAN bridge | VM ↔ VM across machines | one L2 segment spanning physical hosts |
| routed veth | host ↔ rootless namespace | makes a node's own address reachable |

The third is the one that is easy to miss. Without it the first two are a
network the nodes cannot use.

---

## Choosing a transport: what it costs

Measured with iperf3 on this hardware, 2-vCPU guests:

| path | throughput | vs. the link |
|---|---|---|
| raw LAN, hypervisor to hypervisor | 928 Mbit/s | ceiling |
| VM to VM across hosts, plain VXLAN | 896 Mbit/s | −3.4% |
| VM to VM across hosts, through WireGuard | 809 Mbit/s | −13% |
| VM to VM **on one hypervisor**, no crypto | 25,682 Mbit/s | — |
| VM to VM **on one hypervisor**, WireGuard | 1,740 Mbit/s | **−93%** |
| ugnis over wifi, any transport | 57–66 Mbit/s | the wifi |

**One number explains the whole table: WireGuard tops out near 1.7–1.8 Gbit/s
on a 2-vCPU guest.**

Below that ceiling the link is the limit and encryption costs about ten percent
— and that ten percent is encapsulation and MTU, not cipher; the CPU was 45%
idle during the gigabit run. Above the ceiling the cipher is the limit and
everything else is discarded: a 25 Gbit/s path collapses to 1.7.

So the crossover is around 1–2 Gbit/s, and it moves with core count because
WireGuard parallelises. Encrypt anything at or below a gigabit — WAN, site to
site, ordinary LAN. Route anything at 10 Gbit or in one rack, where encryption
would throw away most of the bandwidth.

The 25 Gbit/s figure is VM to VM through a hypervisor bridge, so it is memory
bandwidth rather than a wire. It is the right comparison for two nodes on one
machine and the wrong one for a 25 GbE fabric.

For ugnis none of this mattered: wifi caps the path at ~60 Mbit/s, two orders
of magnitude below the cipher ceiling, so encryption is free there and the
tunnel is the obvious choice. For study-pc ↔ oras either would do; routed was
chosen because it also makes a node's address its real address.

---

## Address plan

Three of these are per machine. The pod and service subnets are cluster-wide
and must match everywhere.

| | study-pc | oras VM 1 | ugnis VM |
|---|---|---|---|
| libvirt `default` | 192.168.122.71 | 192.168.122.61 | 192.168.122.51 |
| VXLAN segment | 10.78.0.71 | 10.78.0.21 | — |
| node subnet | 10.89.43.0/24 | 10.89.21.0/24 | 10.89.51.0/24 (local only) |
| veth transit | 10.99.43.0/30 | 10.99.21.0/30 | — |
| tunnel address | — | — | 10.99.0.3, 10.99.0.4 |

The node subnet is the one people get wrong. kinc derives it from the published
API port unless told otherwise, so on several machines leaving it implicit
means giving each machine a different externally visible port. Set
`KINC_NODE_SUBNET`.

Note what the ugnis column says: its nodes still get podman addresses
(`10.89.51.x`), and those addresses are never used between machines. The
node's *identity* is its tunnel address, set from `/etc/kinc/wg/address`.

---

## Building it

### 1. An L2 segment between the routed machines

```bash
# On each host, with its own and the other's LAN address:
sudo ip link add vxlan0 type vxlan id 100 \
     local "$LOCAL" remote "$REMOTE" dstport 4789
sudo ip link add br-vxlan type bridge
sudo ip link set vxlan0 master br-vxlan
sudo ip link set vxlan0 up && sudo ip link set br-vxlan up
sudo ip addr add 10.78.0.41/24 dev br-vxlan
```

Give each VM a second NIC on `br-vxlan` and a static address on `10.78.0.0/24`.

**MTU.** VXLAN costs 50 bytes, so the segment runs at 1450. Put WireGuard under
it as well and it is 1390 (1500 → 1440 → 1390), verified by DF probe: a 1362
payload passes, 1363 is rejected. Everything on the segment, VM NICs included,
has to agree.

**Do not bridge the hypervisors' `default` networks.** Both are
`192.168.122.1/24` with their own dnsmasq; bridging them puts two DHCP servers
and two gateways with the same address on one segment.

### 2. Node subnets and the routed veth

```bash
# On the VM holding 10.89.21.0/24, naming its peers:
./tools/install-node-veth.sh 10.89.21.0/24 10.99.21.0/30 \
    10.78.0.71=10.89.43.0/24
```

Afterwards each VM routes its peers' node subnets over the segment:

```
--- 192.168.122.71 ---
  route 10.89.21.0/24 via 10.78.0.21 (dev enp2s0)
  trusted: kincv0 enp2s0
--- 192.168.122.61 ---
  route 10.89.43.0/24 via 10.78.0.71 (dev enp2s0)
  trusted: kincv0 enp2s0
```

Three things this gets right that a hand-rolled version usually does not:

- **It is a service, not a one-shot.** podman's rootless namespace is created
  with the first container and destroyed with the last, taking the veth and its
  routes with it. Replace a node by hand and the host keeps routing that subnet
  to an interface that is gone: egress works, ingress does not, nothing logs
  it. It presents as an etcd member that was announced and never started. The
  tell is a host route table missing a route for its **own** local subnet while
  listing every remote one.
- **Routed, not bridged.** A veth enslaved to the podman bridge makes replies
  leave the interface they arrived on, and they are dropped.
- **Two masquerade exemptions.** Both the node subnets and the transit subnets
  must escape netavark's masquerade.
- **A client outside the cluster needs a route back.** The routes above carry
  node-to-node traffic, which is what forms the cluster. A client on some other
  network - a load-balanced address, an appliance arriving over a VPN - reaches a
  node on the strength of the host's own routing, and its reply leaves the
  namespace looking for a return route that only exists for the peer subnets. The
  request arrives, the reply is dropped, and the address reads as a backend that
  is up and answering nothing. Every network clients arrive from belongs in the
  same exemptions and routes as the peers.

### 3. The gateway, for the tunnelled machine

An encrypted node speaks WireGuard; a routed node speaks none. **They cannot
peer directly**, so one end terminates the tunnel and routes into the pod
subnets the veths already expose:

```bash
sudo ip link add wg-gw type wireguard
sudo wg set wg-gw listen-port 51820 private-key /path/to/gw.key \
     peer "$CP3_PUB" allowed-ips "10.99.0.3/32" persistent-keepalive 25
sudo wg set wg-gw peer "$W3_PUB"  allowed-ips "10.99.0.4/32"
sudo ip addr add 10.99.0.254/24 dev wg-gw
sudo ip link set wg-gw mtu 1420 up
sudo sysctl -qw net.ipv4.ip_forward=1
```

It lives on the **hypervisor**, not in a VM, because the tunnelled side's VMs
sit behind their own libvirt NAT and can only dial outbound to a LAN address.

**`allowed-ips` is three things**: an egress peer selector, an ingress filter,
and — crucially — *not a route*. A peer advertising subnets beyond the
interface's own prefix needs explicit routes, or the tunnel handshakes and
carries nothing.

**The bug only a hybrid exposes.** Traffic from a routed-side container to the
tunnelled node was silently dropped: netavark masqueraded it to the veth
transit address, which is not in that peer's `allowed-ips`, so WireGuard
discarded it at ingress — invisible even to tcpdump on `wg0` at the far end.
The node stayed Ready throughout. Only `kubectl exec` surfaced it, because that
is the one path that runs API server → kubelet.

### 4. A name for the control plane

libvirt's dnsmasq already serves the VMs, and **its records reach inside the
node containers**: container → `10.89.x.1` (aardvark-dns) → the VM's resolver,
which is dnsmasq at `192.168.122.1`.

```bash
for ip in 10.89.43.2 10.89.21.3 10.99.0.3; do
  sudo virsh net-update default add dns-host \
    "<host ip='$ip'><hostname>api.kinc</hostname></host>" --live --config
done
```

Removing one record must match on the **IP alone** —
`"<host ip='10.89.43.2'/>"` — because libvirt matches `dns-host` by hostname
and every record in the set shares it.

**Each hypervisor runs its own dnsmasq and nothing synchronises them.** A VM
resolves through its own host, so a record added on one is invisible to VMs on
another, and the failure is a node that cannot find the control plane rather
than a DNS error. Add every record on every hypervisor.

---

## Growing the cluster

The cluster was built one node at a time, never more than one new thing at
once, so that each failure had exactly one candidate cause.

### One control plane

```
  api.kinc -> 10.89.43.2 on all three hypervisors
  auditing 22 resource types
  t0 16:29:25
  t1 16:35:02  (deploy finished)
    kinc-dns-control-plane     Ready     control-plane  10.89.43.2
  endpoint: controlPlaneEndpoint: api.kinc:6443
```

5m37s from nothing to a Ready control plane, with audit and Faro capturing from
the first node. The endpoint is a **name** from the very first `kubeadm init` —
that decision cannot be made later without surgery, and the whole second half
of this document is about why.

### A worker on the same machine

```
  t0 16:35:07
  kinc-dns-w1: worker, address 10.89.43.3, podman 10.89.43.3
  t+15s ready=1/1
  t+60s ready=2/2
  all ready at 16:36:27
```

80 seconds. Nodes carry no role until one is applied from the control plane —
`join-host.sh` holds no cluster credentials by design, so it cannot label its
own node (NodeRestriction forbids it). It prints the command instead.

### A worker on a second machine

```
  t0 16:36:43
  kinc-dns-w2: worker, address 10.89.21.2, podman 10.89.21.2
  t+75s ready=3/3
  all ready at 16:38:23
```

100 seconds, and the first node whose address lives on another physical
machine. Proving that actually crossed a machine boundary took a second step,
because the obvious test does not:

```
=== Verifying pod traffic crosses nodes ===
✅ traceflow crossed the tunnel:
   node kinc-dns-w1:
      Forwarding/Output -> Forwarded tunnelDst=10.89.43.2
   node kinc-dns-control-plane:
      Forwarding/Output -> Delivered
```

A scheduler-chosen pair of pods can land on two nodes of the *same* machine and
pass a "cross-node" test while never leaving the hypervisor. Pinning both ends
is what makes it a machine boundary:

```
  server pinned to kinc-dns-control-plane (study-pc), client to kinc-dns-w2 (oras)
  this pair is a real machine boundary, which crossnode's scheduler-chosen pair was not
✅ kinc-dns-w2 reached kinc-dns-control-plane across the tunnel
```

### A second control plane, on the second machine

```
  t0 16:39:44
  kinc-dns-cp2: control-plane, address 10.89.21.3, podman 10.89.21.3
  audit env in quadlet: 1
  CA mount in quadlet:  1
  certificateKey in join config: 0
  t+105s control-planes=2 ready=3/4
  t+180s control-planes=2 ready=4/4
  all ready at 16:43:50
  --- kubeadm-certs Secret (must not exist) ---
    Error from server (NotFound): secrets "kubeadm-certs" not found
```

4m06s, unattended, and **joined the same way a worker joins**. Three details
make that possible:

- `certificateKey in join config: 0` — there is none.
- The `kubeadm-certs` Secret does not exist, and never did. `--upload-certs`
  creates one that **expires two hours after it is created**, so a cluster
  grown the next day cannot use it.
- Instead, all four pieces of shared control-plane material are minted up front
  — cluster CA, front-proxy CA, etcd CA and the service-account keypair — and
  mounted at `/etc/kinc/ca`. The join runs with
  `--skip-phases=preflight,control-plane-prepare/download-certs`.

A control-plane join with no material is refused outright rather than being
allowed to mint its own CA, which is a split-brain that stays invisible until
something tries to validate a token.

### A control plane and a worker over WireGuard

```
  gateway pub lT8jreKMDR3jl2DHKfrg...  cp3 Z10xK2GMFxm3...  w3 M0KOOSLCypUc...
  wg-gw: 10.99.0.254/24 peers=2
  pod routes on hypervisor: 3
```

then both ugnis nodes at once:

```
  t0 16:45:01
  kinc-dns-cp3: control-plane, address 10.99.0.3, podman 10.89.51.3
  kinc-dns-w3: worker,        address 10.99.0.4, podman 10.89.51.4
  t+105s control-planes=3 ready=6/6
  all ready at 16:47:56
    kinc-dns-control-plane     Ready  control-plane  10.89.43.2
    kinc-dns-cp2               Ready  control-plane  10.89.21.3
    kinc-dns-cp3               Ready  control-plane  10.99.0.3
    kinc-dns-w1                Ready  worker         10.89.43.3
    kinc-dns-w2                Ready  worker         10.89.21.2
    kinc-dns-w3                Ready  worker         10.99.0.4
```

2m55s to add a third machine, over wifi, behind NAT, with a control plane on
it. Note the node list: `10.99.0.3` and `10.99.0.4` are tunnel addresses
sitting beside podman addresses, and nothing in the cluster distinguishes them.

Three control planes across three machines tolerates losing any one machine.
Two on one machine and one on another does **not**: losing the first machine
loses quorum. Placement is the whole point of spreading them.

---

## Losing things

### A control plane that is not the first

```
  stopped at 16:48:43
  t+20s  healthz=ok write=ok control-planes-ready=3/3 nodes-ready=6/6
  t+60s  healthz=ok write=ok control-planes-ready=2/3 nodes-ready=5/6
  t+240s healthz=ok write=ok control-planes-ready=2/3 nodes-ready=5/6
  --- workload after ---
    web-674b864cb9-8gwsm  Running  kinc-dns-w3
    web-674b864cb9-g4hvq  Running  kinc-dns-w2
    web-674b864cb9-xd4rv  Running  kinc-dns-w1
```

Writes kept working — two of three members is a quorum — and the workload never
moved. This is the case everyone expects to work, and it does.

One qualification, measured on a different cluster and so reported as such: the
member stopped above was not the etcd leader. On a four-machine cluster reached
through a load-balanced address, stopping the machine that held the **leader**
gave roughly a minute in which that address refused connections and a surviving
control plane's API answered a TLS handshake and then timed out. It recovered
with no intervention once the election settled. The quorum arithmetic is the
same either way — what moves is the leader, and the gap is the election plus the
front end noticing. It is worth knowing before reading it as a failure to fail
over.

### A tunnel node that is restarted

Restarting `kinc-dns-cp3` used to lose the cluster, and the reason is worth
keeping. `wg0` lives inside the node container, so it dies with it. Bringing it
up was preflight's job, and preflight is skipped on an already-initialised node
via `ConditionPathExists` — **a unit skipped on an unmet condition reports
success**. systemd showed a clean start, and the node came up with no tunnel.

The fix is a separate `kinc-tunnel.service`, ordered before preflight, kubeadm
and kubelet, with no init-marker condition, idempotent, and a no-op when there
is no tunnel material:

```
  wg0 before restart: 10.99.0.3/24
  restarted at 17:08:42
  t+15s ready=6/6
  recovered from restart at 17:09:06
```

24 seconds, 6/6. Assert the effect, never the unit state.

### The control plane that ran `kubeadm init`

This is the interesting one, and it was run twice on the same cluster with one
variable changed.

**With `api.kinc` resolving to one address.** Stopped at 17:09:47; at 17:11:05,
78 seconds later:

```
    kinc-dns-control-plane  NotReady
    kinc-dns-cp2            Ready
    kinc-dns-cp3            Ready
    kinc-dns-w1             NotReady
    kinc-dns-w2             NotReady
    kinc-dns-w3             NotReady
```

`healthz=ok write=ok` throughout: etcd kept quorum and the API kept serving
through cp2. **Four of six nodes dropped anyway.** The two that stayed Ready
are the two control planes, which talk to their own local API server.

A name with a single A record is exactly as fragile as an address — every
kubelet resolves `api.kinc` to the one dead machine. The failover comes from
having several A records, not from using a name.

**With `api.kinc` resolving to all three.** Same cluster, same test. Verified
first that every node really sees all three, because the whole result depends
on it:

```
  kinc-dns-w1  resolves[10.89.21.3 10.89.43.2 10.99.0.3]
  kinc-dns-w2  resolves[10.89.21.3 10.89.43.2 10.99.0.3]
  kinc-dns-w3  resolves[10.89.21.3 10.89.43.2 10.99.0.3]
  ...
  first control plane STOPPED at 17:24:54
  tick=1  17:23:29 healthz=ok write=ok ready=6/6
  tick=6  17:25:48 healthz=ok write=ok ready=5/6
  tick=12 17:28:36 healthz=ok write=ok ready=5/6
  tick=18 17:31:23 healthz=ok write=ok ready=5/6
  probe end 17:31:51 ticks_completed=18
```

5 of 6 Ready for the full eight minutes, the only NotReady node being the one
deliberately stopped. The failover is visible in the connection table: before
the stop, cp1 held five connections to its own `10.89.43.2`; afterwards **no
node anywhere holds a single connection to that address** — they are all on
`10.89.21.3` and `10.99.0.3`.

| | one A record | three A records |
|---|---|---|
| nodes Ready after losing cp1 | 2 of 6, at t+78s | 5 of 6, for 8 minutes |
| healthz / writes | ok (via cp2) | ok, all 18 ticks |
| connections to the dead address | every kubelet | none |

Two honest qualifications, because both change how much the table proves:

- The single-A case was only observed for **118 seconds** before the control
  plane was restored, so this does not show it never recovers. It cannot
  recover while the one address it resolves is the machine that is down, which
  is the mechanism, but the experiment did not run long enough to say more.
- In the three-A case most workers were already spread across cp2 and cp3
  before the stop, so they never had to fail over at all. That is the mechanism
  rather than a confound — with one record they had nowhere else to be. **The
  name is not what buys the resilience; the number of addresses behind it is.**

### Replacing it

With the endpoint as an **address**, the replacement has to reuse the dead
node's address, and two separate records have to be repointed first —
`kube-system/kubeadm-config` and `kube-public/cluster-info`. Patching only the
first makes the join dial the address it is itself about to become:

```
error execution phase control-plane-prepare/download-certs:
  Get "https://10.89.43.2:6443/...": connect: connection refused
```

Eight manual steps end to end: evict the etcd member, delete the Node, mint a
certificate key, patch both records, re-assert the veth, promote the etcd
learner, run `mark-control-plane`.

With the endpoint as a **name**, the same operation is: stop the node, remove
its etcd member and Node object, delete its A record, add the replacement's,
join at **any free address**.

| | endpoint is an IP | endpoint is `api.kinc` |
|---|---|---|
| surviving nodes when it dies | all workers NotReady | only the dead node |
| endpoint records to patch | 2 | 0 |
| replacement address | must reuse the dead one | any free address |
| join | failed, then 8 manual steps | unattended |

---

## Rescheduling a pod across the transport boundary

The interesting case is not a pod moving between two nodes on one machine. It
is a pod moving from a **routed** node on one hypervisor to a **tunnelled**
node on another, over wifi, behind NAT — with a client that never moves.

Setup: a server confined by `nodeAffinity` to `kinc-dns-w2` (oras, routed) or
`kinc-dns-w3` (ugnis, WireGuard), started on w2; a client pinned to
`kinc-dns-w1` (study-pc, routed), so it is always on the opposite transport.
Draining w2 leaves exactly one legal landing site, on the far side of WireGuard:

```
  BEFORE: server pod server-674c5797b-qp6zj on kinc-dns-w2   (oras, routed veth)
          client on kinc-dns-w1   (study-pc, routed veth)
  client -> server across the routed fabric:
    HTTP 200 in 0.020507s

  draining kinc-dns-w2 at 17:49:22
  pod/server-674c5797b-qp6zj evicted
  node/kinc-dns-w2 drained

  AFTER at 17:49:34: server pod server-674c5797b-cdkwp on kinc-dns-w3   (ugnis, WireGuard)
  pod identity changed: qp6zj -> cdkwp ; node changed: kinc-dns-w2 -> kinc-dns-w3

  client (routed, study-pc) -> server (WireGuard, ugnis), service unchanged:
    HTTP 200 in 0.018014s
    HTTP 200 in 0.017639s
    HTTP 200 in 0.007719s
```

**12 seconds**, across both a machine boundary and a transport boundary. The
client never moved and its Service address never changed: it kept getting HTTP
200, first from a server one routed hop away, then from a server on the far
side of a tunnel on a different machine.

Nothing in the deployment mentions transports, hypervisors or addresses. The
affinity is over an ordinary node label. A node whose address is a WireGuard
address and a node whose address is a podman address are interchangeable to the
scheduler — which is the result that makes the hybrid worth having.

**Two traps this test fell into first**, both of which produce a passing run
that proves nothing:

- **A blanket toleration defeats drain.** The workload carried
  `tolerations: [{operator: Exists}]`, which also tolerates
  `node.kubernetes.io/unschedulable` — the taint `cordon` adds. `drain`
  reported `node/kinc-dns-w2 drained` and exited 0 while the replacement pod
  was scheduled straight back onto the node just drained. The node read
  `unschedulable=true` throughout, so nothing in the state looked wrong.
- **Unpinning a pod moves it before the drain can.** Removing a `nodeSelector`
  recreates the pod immediately; by the time the drain ran, the node was
  already empty and the "move" had gone to a node on the *same* transport.

Both are why the capture records the pod **name** either side of the drain, not
just the node: a node field can change for reasons the drain had nothing to do
with.

---

## What was recording, and what it missed

Audit and Faro ran from the first node onwards.

```
  AUDIT  cp1  4,324 events  4.7 MB  16:32:05 -> 17:52:21
         cp2  (its own file) 3.7 MB  16:41:28 -> 17:52:36
  FARO   3,748 events  3.0 MB  over 4 files
```

Faro recorded the experiment itself — the `xport` namespace ADDED/UPDATED/
DELETED with UIDs, node UPDATEs for w2 and w3 either side of the drain, and the
Events that went with them, across all six nodes.

**Finding 1 — Faro does not survive what audit survives.**

Faro runs as a bootstrap static pod on the **first control plane**, so it dies
with that node. Its four files are not rotations, they are four lifetimes, and
the gaps between them are the three control-plane-loss experiments:

```
  file 1  16:32:13 -> 17:09:17   1311 events
          GAP 2m35s   <- first CP stopped (single-A endpoint test)
  file 2  17:11:52 -> 17:12:40    750 events
          GAP 9m01s   <- first CP stopped
  file 3  17:21:41 -> 17:24:47    771 events
          GAP 8m27s   <- first CP stopped (multi-A endpoint test)
  file 4  17:33:14 -> 17:51:33    916 events
```

About 20 minutes blind, and every blind minute is a minute the cluster was
losing a control plane. The cluster was *fine* through the longest of them — 5
of 6 Ready, writes succeeding on all 18 ticks — so this is the observer
failing, not the observed.

cp1's **audit** log has the same three gaps, for the same reason. But audit is
per-apiserver and each control plane keeps its own: cp2's log has no gap over
60 seconds across the entire run, and holds 365 events inside cp1's longest
blind window. The cluster's audit record is complete; it is just distributed.
Reading one node's file and concluding there was an outage would be wrong.

Put Faro on a node that is not the one under test, or run it as a workload the
scheduler can move. Collect audit from every control plane.

**Finding 2 — this audit policy records no writes.**

Searching the audit logs for the drain returned nothing, on either control
plane. The policy is the reason, not a lost record: 23 rules, 22 of them
identical — `level: Metadata`, `verbs: ["get","list","watch","delete"]` — over
22 resource types. A grep for `create|update|patch` across the file does not
match. The observed verb counts agree exactly:

```
  cp1  watch 2298  get 1702  list 334  delete 21
  cp2  watch 1988  get 1086  list 394  delete 24
```

So this configuration answers *who read it* and *who deleted it*, and cannot
answer *who changed it*. Cordoning w2, creating the Deployment and patching the
pod spec all went unrecorded. The omission is easy to miss because the reads
around them **are** recorded — cp2 holds the `xport` namespace delete and the
gets that followed — so the log looks busy and the expected resource names are
all present, just never with a write beside them.

---

## Things that cost time

**A rebuilt cluster talking to its predecessor.** Tear a named cluster down on
one machine and the others keep running *and keep answering to the name*. The
new cluster dials the old one:

```
x509: certificate signed by unknown authority (possibly because of
"crypto/rsa: verification error" ... candidate authority certificate "kubernetes")
```

while `/healthz` returns 200 — the 200 from the new local API server, the
failure from the old remote one. Both CAs are `CN=kubernetes`, so even the
error text looks like one certificate. A name is cluster-wide state: tear down
every machine and repoint the records before rebuilding.

**A NIC on a segment with no DHCP server blocks boot.** It holds
`network-online.target`, so sshd never starts. The VM answers ping and refuses
SSH, which looks like a broken sshd and is not.

**NetworkManager removing routes and addresses.** Anything set with a bare
`ip route` or `ip addr` is undone on the next NM event — and on a fresh NIC, NM
claims it, starts DHCP against a segment with no server, and clears the address
when that fails, so it works for a minute and then vanishes. Use
`nmcli con modify +ipv4.routes` and `ipv4.method manual`.

**firewalld reverting zone changes.** A runtime-only `--zone=trusted
--change-interface` is undone by the next reload, and the symptom arrives much
later as `host unreachable - admin prohibited filter`. Use `--permanent` and
reload.

**Kernel modules nothing loads.** `openvswitch` and `geneve` ship with the
kernel but nothing loads them, and kinc tests for *loaded*. Use
`modules-load.d`.

**A tool that is not in the node image.** `ping`, `openssl`, `etcdctl` and
`python3` are absent. An "unreachable" result from `ping` means only that ping
is missing; use `curl` or bash's `/dev/tcp`. For etcd, `crictl exec` into the
etcd static pod. `jq` and `yq` are present.

**Nothing here survives a hypervisor reboot** unless it was made persistent.
The VXLAN links and the gateway are runtime state.

---

## A note on measuring any of this

Three results in this run were wrong on first reading, and all three failed the
same way: **the thing doing the measuring broke, and its failure looked exactly
like the result being looked for.**

- A probe reaching the API through an SSH tunnel reported
  `write=FAIL nodes-ready=0/6` for seven minutes. The cluster was healthy the
  whole time — 5 of 6 Ready, all three etcd members `started`. The tunnel had
  died.
- Two runs of the drain test overlapped and overwrote each other's remote
  script, because the harness wrote every script to a fixed `/tmp/_r.sh`. The
  second run then "observed" a pod the first run's eviction had just created.
- A probe loop appeared to show a cluster recovering from 2/6 to 6/6 under a
  single A record. It was recovering from the control plane being *restored*
  partway through the loop, which the log never mentioned.

What each would have cost is a confident paragraph in this document asserting
the opposite of the truth. Three habits caught them:

- **Prove the probe ran before believing its result.** Number every tick and
  assert the count at the end; a probe that cannot show its own liveness is not
  evidence. This also caught a probe that never started at all, because
  `podman exec` without `-i` silently wrote an empty script.
- **Check the subject, not just the log.** When the log says total failure, go
  and look at etcd membership and node status directly.
- **Assert the mutation, not the command.** Record the pod name either side of
  a drain, the established connections either side of a failover, the
  resolution inside the container before the test. `drain` exiting 0 and a node
  reading `unschedulable=true` were both true while nothing had moved.
