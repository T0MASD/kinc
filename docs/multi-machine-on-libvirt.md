# One cluster across three machines, two transports

A worked case: a six-node Kubernetes cluster spread over three physical
machines, where some nodes reach each other over plain routed networking and one
reaches them through an encrypted tunnel, and where the control plane can be
replaced without the cluster noticing.

Everything below was built and measured. The numbers and the console output are
from that cluster, not from reasoning about what should happen.

## The cluster

| node | machine | transport | node address |
|---|---|---|---|
| `kinc-hyb-control-plane` | study-pc VM | routed veth | `10.89.43.2` |
| `kinc-hyb-cp2` | oras VM 1 | routed veth | `10.89.21.3` |
| `kinc-hyb-cp3` | oras VM 2 | routed veth | `10.89.22.3` |
| `kinc-hyb-w1` | oras VM 1 | routed veth | `10.89.21.2` |
| `kinc-hyb-w2` | oras VM 2 | routed veth | `10.89.22.2` |
| `kinc-hyb-w3` | **ugnis VM** | **WireGuard** | **`10.99.0.2`** |

study-pc and oras sit in the same rack on a gigabit LAN. ugnis is on wifi, in a
different place, behind its own NAT. That asymmetry is the point: the two halves
want different transports, and a cluster should not have to choose one for all
of its nodes.

---

## Why there are three network layers

kinc nodes are rootless podman containers, and rootless podman puts its network
in a user namespace of its own. Every machine's podman allocates from the same
range, so two machines hand their containers **identical addresses** - both
`10.89.x.2` - and neither can reach the other's.

Bridging the hypervisors does not fix this. The namespace is the boundary, not
the LAN. This is worth stating plainly because bridging is the first thing to
reach for, and it produces a setup that looks right and does not work.

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

**One number explains the whole table: WireGuard tops out near 1.7–1.8 Gbit/s on
a 2-vCPU guest.**

Below that ceiling the link is the limit and encryption costs about ten percent -
and that ten percent is encapsulation and MTU, not cipher; the CPU was 45% idle
during the gigabit run. Above the ceiling the cipher is the limit and everything
else is discarded: a 25 Gbit/s path collapses to 1.7.

So the crossover is around 1–2 Gbit/s, and it moves with core count because
WireGuard parallelises. Encrypt anything at or below a gigabit - WAN, site to
site, ordinary LAN. Route anything at 10 Gbit or in one rack, where encryption
would throw away most of the bandwidth.

The 25 Gbit/s figure is VM to VM through a hypervisor bridge, so it is memory
bandwidth rather than a wire. It is the right comparison for two nodes on one
machine and the wrong one for a 25 GbE fabric.

For ugnis none of this mattered: wifi caps the path at ~60 Mbit/s, two orders of
magnitude below the cipher ceiling, so encryption is free there and the tunnel
is the obvious choice. For study-pc ↔ oras on a gigabit LAN either would do;
routed was chosen because it also makes a node's address its real address.

---

## Address plan

Three of these are per machine. The pod and service subnets are cluster-wide and
must match everywhere.

| | study-pc | oras VM 1 | oras VM 2 | ugnis VM |
|---|---|---|---|---|
| LAN (physical) | 192.168.88.41 | 192.168.88.101 | — | wifi, NAT |
| libvirt `default` | 192.168.122.71 | 192.168.122.61 | 192.168.122.62 | 192.168.122.51 |
| VXLAN segment | 10.78.0.71 | 10.78.0.21 | 10.78.0.22 | — |
| node subnet | 10.89.43.0/24 | 10.89.21.0/24 | 10.89.22.0/24 | tunnel only |
| veth transit | 10.99.43.0/30 | 10.99.21.0/30 | 10.99.22.0/30 | — |
| tunnel address | — | — | — | 10.99.0.2 |

The node subnet is the one people get wrong. kinc derives it from the published
API port unless told otherwise, so on several machines leaving it implicit means
giving each machine a different externally visible port. Set
`KINC_NODE_SUBNET`.

---

## 1. An L2 segment between the routed machines

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

## 2. Node subnets and the routed veth

```bash
# On the VM holding 10.89.21.0/24, naming its peers:
./tools/install-node-veth.sh 10.89.21.0/24 10.99.21.0/30 \
    10.78.0.71=10.89.43.0/24 10.78.0.22=10.89.22.0/24
```

Three things this gets right that a hand-rolled version usually does not:

- **It is a service, not a one-shot.** podman's rootless namespace is created
  with the first container and destroyed with the last, taking the veth and its
  routes with it. Replace a node by hand and the host keeps routing that subnet
  to an interface that is gone: egress works, ingress does not, nothing logs it.
  It presents as an etcd member that was announced and never started. The tell
  is a host route table missing a route for its **own** local subnet while
  listing every remote one.
- **Routed, not bridged.** A veth enslaved to the podman bridge makes replies
  leave the interface they arrived on, and they are dropped.
- **Two masquerade exemptions.** Both the node subnets and the transit subnets
  must escape netavark's masquerade.

## 3. The gateway, for the tunnelled machine

An encrypted node speaks WireGuard; a routed node speaks none. **They cannot
peer directly**, so one end has to terminate the tunnel and route into the pod
subnets the veths already expose:

```bash
sudo ip link add wg-gw type wireguard
sudo wg set wg-gw listen-port 51820 private-key /path/to/gw.key \
     peer "$NODE_PUB" allowed-ips "10.99.0.2/32" persistent-keepalive 25
sudo ip addr add 10.99.0.254/24 dev wg-gw
sudo ip link set wg-gw mtu 1420 up
sudo sysctl -qw net.ipv4.ip_forward=1
```

It lives on the **hypervisor**, not in a VM, because the tunnelled side's VMs
sit behind their own libvirt NAT and can only dial outbound to a LAN address.

**`allowed-ips` is three things**: an egress peer selector, an ingress filter,
and - crucially - *not a route*. A peer advertising subnets beyond the
interface's own prefix needs explicit routes, or the tunnel handshakes and
carries nothing.

**The bug only a hybrid exposes.** Traffic from a routed-side container to the
tunnelled node was silently dropped: netavark masqueraded it to the veth transit
address, which is not in that peer's `allowed-ips`, so WireGuard discarded it at
ingress - invisible even to tcpdump on `wg0` at the far end. The node stayed
Ready throughout. Only `kubectl exec` surfaced it, because that is the one path
that runs API server → kubelet.

## 4. A name for the control plane

libvirt's dnsmasq already serves the VMs, and **its records reach inside the node
containers**: container → `10.89.x.1` (aardvark-dns) → the VM's resolver, which
is dnsmasq at `192.168.122.1`.

```bash
for ip in 10.89.43.2 10.89.21.3 10.89.22.3; do
  sudo virsh net-update default add dns-host \
    "<host ip='$ip'><hostname>api.kinc</hostname></host>" --live --config
done
```

Removing one record must match on the **IP alone** -
`"<host ip='10.89.43.2'/>"` - because libvirt matches `dns-host` by hostname and
every record in the set shares it.

**Each hypervisor runs its own dnsmasq and nothing synchronises them.** A VM
resolves through its own host, so a record added on one is invisible to VMs on
another, and the failure is a node that cannot find the control plane rather
than a DNS error.

---

## Placing the control planes

One per machine, so no single machine holds a quorum. Growing from one to three,
with the node list polled every 20s:

```
  t+20s   control-planes=1 ready=1
  t+100s  control-planes=2 ready=1
  t+120s  control-planes=3 ready=2
  t+200s  control-planes=3 ready=3
CP_QUORUM_UP
    kinc-hyb-control-plane  Ready  control-plane  10.89.43.2
    kinc-hyb-cp2            Ready  control-plane  10.89.21.3
    kinc-hyb-cp3            Ready  control-plane  10.89.22.3
    kinc-hyb-w1             Ready  worker         10.89.21.2
    kinc-hyb-w2             Ready  worker         10.89.22.2
    kinc-hyb-w3             Ready  worker         10.99.0.2
```

A control plane takes about a minute to join and another minute to go Ready
behind its CNI. Note `kinc-hyb-w3` at `10.99.0.2` - a tunnel address in a node
list where everything else is a podman address. To the cluster they are the same
kind of thing.

Three CPs across three machines tolerates losing any one machine. Two CPs on one
machine and one on another does **not**: losing the first machine loses quorum.
Placement is the whole point of spreading them.

## Losing a control plane that is not the first

Stopping `kinc-hyb-cp3`, polling the API through the others:

```
  t+47s  healthz=ok write=ok cp-ready=3/3 nodes-ready=6/6
  t+63s  healthz=ok write=ok cp-ready=2/3 nodes-ready=5/6
  t+186s healthz=ok write=ok cp-ready=2/3 nodes-ready=5/6
  --- workload unaffected? ---
    affinity-app-5f55cbd48d-kb695  Running  kinc-hyb-w3
```

Writes kept working throughout - two of three members is a quorum - and the
workload never moved. This is the case everyone expects to work, and it does.

## Losing the control plane that ran `kubeadm init`

The same test on the **first** control plane, watched through `cp2`:

```
  t+58s  via-cp2 healthz=ok write=ok nodes-ready=6/6
  t+78s  via-cp2 healthz=ok write=ok nodes-ready=2/6
  t+282s via-cp2 healthz=ok write=ok nodes-ready=2/6
```

The API is fine. **Four of six nodes fall off and stay off.**

The reason is `controlPlaneEndpoint`. It is written into every node's
`kubelet.conf` when that node joins, and at the time it was the first control
plane's address. etcd kept quorum, the API kept serving through `cp2` - and
every kubelet still dialled a machine that was gone. The two remaining Ready
nodes were the two control planes that talk to their own local API server.

Nothing in that output says "DNS". It says the cluster lost four nodes while the
control plane reported healthy, which is why this is the failure worth
reproducing before relying on an address.

## Replacing it

With the endpoint as an **address**, the replacement has to reuse the dead node's
address, and two separate records have to be repointed first -
`kube-system/kubeadm-config` and `kube-public/cluster-info`. Patching only the
first makes the join dial the address it is itself about to become:

```
error execution phase control-plane-prepare/download-certs:
  Get "https://10.89.43.2:6443/...": dial tcp 10.89.43.2:6443: connect: connection refused
```

Eight manual steps end to end: evict the etcd member, delete the Node, mint a
certificate key, patch both records, re-assert the veth, promote the etcd
learner, run `mark-control-plane`.

With the endpoint as a **name**, the same operation is: stop the node, remove its
etcd member and Node object, delete its A record, add the replacement's, join at
**any free address**. Measured side by side on this cluster:

| | endpoint is an IP | endpoint is `api.kinc` |
|---|---|---|
| surviving nodes when it dies | all workers NotReady | only the dead node |
| endpoint records to patch | 2 | 0 |
| replacement address | must reuse the dead one | any free address |
| join | failed, then 8 manual steps | unattended, 100s |

## Rescheduling a pod across the transport boundary

The interesting case is not a pod moving between two nodes on one machine. It is
a pod moving from a **routed** node on one hypervisor to a **tunnelled** node on
another, over wifi, behind NAT.

A deployment with `nodeAffinity` over two labelled nodes - `kinc-hyb-w1`
(routed, oras) and `kinc-hyb-w3` (tunnelled, ugnis):

```
  labelled:
    kinc-hyb-w1
    kinc-hyb-w3
  placed:
    affinity-app-5f55cbd48d-ftlqv  Running  kinc-hyb-w1
```

Then `kinc-hyb-w1` is stopped:

```
  t+15s  w1=Ready     running-pod-on=kinc-hyb-w1
  t+46s  w1=Ready     running-pod-on=kinc-hyb-w1
  t+61s  w1=NotReady  running-pod-on=kinc-hyb-w3
  RECOVERED on kinc-hyb-w3 after 61s
  final: affinity-app-5f55cbd48d-ftlqv  Terminating  kinc-hyb-w1
  final: affinity-app-5f55cbd48d-kb695  Running      kinc-hyb-w3
```

**61 seconds**, and the new pod is on the other side of both a machine boundary
and a transport boundary. Most of that is the node-monitor grace period, not
anything about the network.

Worth noting what the scheduler was *not* told: nothing in the deployment
mentions transports, hypervisors or addresses. The affinity is over an ordinary
node label. A node whose address is a WireGuard address and a node whose address
is a podman address are interchangeable to it - which is the result that makes
the hybrid worth having.

---

## Things that cost time

**A rebuilt cluster talking to its predecessor.** Tear a named cluster down on
one machine and the others keep running *and keep answering to the name*. The
new cluster dials the old one:

```
x509: certificate signed by unknown authority (possibly because of
"crypto/rsa: verification error" ... candidate authority certificate "kubernetes")
```

while `/healthz` returns 200 - the 200 from the new local API server, the failure
from the old remote one. Both CAs are `CN=kubernetes`, so even the error text
looks like one certificate. A name is cluster-wide state: tear down every
machine and repoint the records before rebuilding.

**NetworkManager removing routes and addresses.** Anything set with a bare
`ip route` or `ip addr` is undone on the next NM event - and on a fresh NIC, NM
claims it, starts DHCP against a segment with no server, and clears the address
when that fails, so it works for a minute and then vanishes. Use
`nmcli con modify +ipv4.routes` and `ipv4.method manual`.

**firewalld reverting zone changes.** A runtime-only `--zone=trusted
--change-interface` is undone by the next reload, and the symptom arrives much
later as `host unreachable - admin prohibited filter`. Use `--permanent` and
reload.

**A tool that is not in the node image.** `ping`, `openssl` and `etcdctl` are
absent. An "unreachable" result from `ping` means only that ping is missing; use
`curl` or bash's `/dev/tcp`. For etcd, `crictl exec` into the etcd static pod.

**Nothing here survives a hypervisor reboot** unless it was made persistent. The
VXLAN links and the gateway are runtime state.
