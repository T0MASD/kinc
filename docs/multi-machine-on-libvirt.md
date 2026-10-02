# Running one kinc cluster across several libvirt machines

A worked setup: one Kubernetes cluster whose nodes live in VMs on different
physical machines, with the control plane replaceable. It is written as a
recipe, but each layer says what it is for, because the obstacles are not
obvious and several of them fail silently.

The lab it describes is two physical hosts, each running libvirt, each with one
or two VMs, each VM running kinc nodes as rootless podman containers.

---

## Why there are three network layers

kinc nodes are rootless podman containers, and rootless podman puts its network
in a user namespace of its own. Every machine's podman allocates from the same
range, so two machines hand their containers **identical addresses** - both
`10.89.x.2` - and neither can reach the other's.

Bridging the hypervisors does not fix this. The namespace is the boundary, not
the LAN: a container's address is private to its machine's rootless namespace no
matter how flat the network underneath is. This is worth stating because
bridging is the first thing to reach for, and it produces a setup that looks
right and does not work.

So three layers, each solving one thing:

| layer | carries | why |
|---|---|---|
| libvirt `default` (NAT) | management, **DNS** | each VM's resolver, and where the control-plane name lives |
| VXLAN bridge | VM ↔ VM across hosts | one L2 segment spanning physical machines |
| routed veth | host ↔ rootless namespace | makes a node's own address reachable |

The third is the one that is easy to miss. Without it the first two are a
network the nodes cannot use.

---

## Address plan

Pick these before building anything. Three of the four must be unique per
machine; the pod and service subnets are cluster-wide and must match everywhere.

| | study-pc | oras VM 1 | oras VM 2 | scope |
|---|---|---|---|---|
| LAN (physical) | 192.168.88.41 | 192.168.88.101 | — | per host |
| libvirt `default` | 192.168.122.71 | 192.168.122.61 | 192.168.122.62 | per VM |
| VXLAN segment | 10.78.0.71 | 10.78.0.21 | 10.78.0.22 | per VM |
| node subnet | 10.89.43.0/24 | 10.89.21.0/24 | 10.89.22.0/24 | **per VM** |
| veth transit | 10.99.43.0/30 | 10.99.21.0/30 | 10.99.22.0/30 | per VM |

The node subnet is the one people get wrong. It is per machine, and kinc derives
it from the published API port unless told otherwise - so on several machines,
leaving it implicit means giving each machine a different externally visible
port. Set `KINC_NODE_SUBNET` instead.

---

## 1. An L2 segment between the hosts

The VMs need to reach each other across physical machines. A VXLAN bridge gives
them one flat segment; the hypervisors are on the same LAN here, so it carries
no encryption of its own.

On each host, with `LOCAL` and `REMOTE` being that host's and the other's LAN
address:

```bash
sudo ip link add vxlan0 type vxlan id 100 \
     local "$LOCAL" remote "$REMOTE" dstport 4789
sudo ip link add br-vxlan type bridge
sudo ip link set vxlan0 master br-vxlan
sudo ip link set vxlan0 up
sudo ip link set br-vxlan up
sudo ip addr add 10.78.0.41/24 dev br-vxlan      # this host's segment address
```

Then give each VM a second NIC on `br-vxlan` (`virsh domiflist` should show it
as `type bridge`, `source br-vxlan`) and a static address on `10.78.0.0/24`.

**MTU.** VXLAN costs 50 bytes, so the segment runs at 1450 rather than 1500. TCP
negotiates around it; anything relying on a 1500-byte path will not.

**More than two hosts** needs a remote per peer - either several `vxlan0`-style
links or `bridge fdb` entries - because `remote` names one.

**If the hosts are not on a trusted network**, put WireGuard under the VXLAN and
expect ~1390 MTU and a throughput ceiling around 1.7 Gbit/s on a 2-vCPU guest;
above that the cipher is the bottleneck. On a trusted LAN, plain VXLAN runs at
line rate.

## 2. Node subnets and the routed veth

On each VM, give kinc a subnet of its own and route it into the rootless
namespace:

```bash
# On the VM holding 10.89.21.0/24, naming its peers on the segment:
./tools/install-node-veth.sh 10.89.21.0/24 10.99.21.0/30 \
    10.78.0.71=10.89.43.0/24 10.78.0.22=10.89.22.0/24
```

That installs a service, adds a route to each peer's node subnet, and puts the
veth and segment interfaces in firewalld's trusted zone.

Three things this gets right that a hand-rolled version usually does not:

- **It is a service, not a one-shot.** podman's rootless namespace is created
  with the first container and destroyed with the last, taking the veth and its
  routes with it. Replace a node by hand and the host keeps routing that subnet
  to an interface that no longer exists: egress works, ingress does not, and
  nothing logs an error. It presents as an etcd member that was announced and
  never started. The tell is a host route table missing a route for its **own**
  local subnet while listing every remote one.
- **Routed, not bridged.** A veth enslaved to the podman bridge makes replies
  leave the interface they arrived on, and they are dropped.
- **Two masquerade exemptions.** Both the node subnets and the transit subnets
  must escape netavark's masquerade. Exempt only the first and inter-node
  traffic reaches the far side as the transit address, which has no route back -
  the reply is lost, and it does not appear on the far interface at all.

Check it with `systemctl is-active kinc-node-veth` and a route to the local
subnet via `kincv0`.

## 3. A name for the control plane

`controlPlaneEndpoint` is written into every node's `kubelet.conf` when it joins.
With an address, that node's identity is load-bearing: replacing it means reusing
its address, and two separate records have to be repointed first. With a name, a
replacement is a DNS update and can take any free address.

**libvirt's dnsmasq already serves the VMs, and its records reach inside the node
containers.** The chain is two hops: container → `10.89.x.1` (aardvark-dns) →
the VM's resolver, which is libvirt's dnsmasq at `192.168.122.1`.

Add one record per control plane, on **every** hypervisor:

```bash
for ip in 10.89.43.2 10.89.21.3 10.89.22.3; do
  sudo virsh net-update default add dns-host \
    "<host ip='$ip'><hostname>api.kinc</hostname></host>" --live --config
done
```

`--live --config` applies immediately and persists; no network restart, so
running VMs are undisturbed. libvirt writes
`/var/lib/libvirt/dnsmasq/default.addnhosts`, and several entries sharing a
hostname become several A records.

**Removing one record must match on the IP alone:**

```bash
sudo virsh net-update default delete dns-host \
  "<host ip='10.89.43.2'/>" --live --config
```

Passing the full `<host ip=...><hostname>...</hostname></host>` is refused with
`multiple matching DNS HOST records were found`, because libvirt matches
`dns-host` by hostname and every record in the set shares it.

**Each hypervisor runs its own dnsmasq.** Nothing synchronises them. A VM
resolves through its own host, so a record added on one host is invisible to VMs
on another - and the failure is a node that cannot find the control plane, not a
DNS error.

Several A records also give failover with nothing in front of the cluster: a
client skips a dead address in milliseconds, and a joining node comes up even
when the records include addresses that are not serving yet.

## 4. The cluster

First control plane, on the machine holding `10.89.43.0/24`:

```bash
echo "api.kinc" > ~/kinc-advertise-addr
CLUSTER_NAME=dns \
KINC_API_BIND=0.0.0.0 \
KINC_ADVERTISE=$HOME/kinc-advertise-addr \
KINC_NODE_SUBNET=10.89.43.0/24 \
KINC_WORKERS=0 \
  ./tools/deploy.sh
```

The name must be in the certificate, so it is fixed when the cluster is created:
a running cluster cannot be renamed without regenerating the API server's
certificates.

Copy the shared control-plane material to any machine that will run a control
plane, and note the CA hash:

```bash
scp -r ~/.local/share/kinc/dns/ca other-vm:~/kinc-ca

openssl x509 -in ~/.local/share/kinc/dns/ca/ca.crt -noout -pubkey \
  | openssl pkey -pubin -outform DER \
  | openssl dgst -sha256 | awk '{print $NF}'
```

Then on each other machine, joining control planes and workers the same way:

```bash
KINC_NET=kinc-dns ./tools/join-host.sh api.kinc <ca-hash> 10.89.21.0/24 \
    kinc-dns-cp2:10.89.21.3:10.89.21.3:control-plane \
    kinc-dns-w1:10.89.21.4:10.89.21.4
```

With the routed veth there is no tunnel, so a node's address is the one it
already has - pass the same value for both fields. `KINC_NET` points at the
cluster's existing podman network rather than creating a second one.

Add each new control plane's address to `api.kinc` on every hypervisor.

---

## Replacing a control plane

With a name, this is the whole procedure:

1. Stop the old node.
2. Remove its etcd member and its Node object.
3. Delete its A record, add the replacement's.
4. Join the replacement with `join-host.sh`, at **any** free address.

Measured on a four-node cluster across three machines: the surviving nodes never
left `Ready`, no endpoint record needed patching, and the join completed
unattended. With an address instead of a name the same operation took eight
manual steps and every worker went `NotReady` the moment the control plane died.

---

## Things that cost time

**A rebuilt cluster talking to its predecessor.** Tear a named cluster down on
one host and the other hosts' control planes keep running *and keep answering to
the name*. The new cluster then dials the old one and reports:

```
x509: certificate signed by unknown authority (possibly because of
"crypto/rsa: verification error" ... candidate authority certificate "kubernetes")
```

while `/healthz` returns 200 - the 200 from the new local API server, the failure
from the old remote one. Both CAs are `CN=kubernetes`, so even the error text
looks like one certificate. A name is cluster-wide state: tear down every host
and repoint the records before rebuilding.

**NetworkManager removing routes and addresses.** Anything set with a bare
`ip route` or `ip addr` is undone on the next NM event. Use profile routes
(`nmcli con modify <con> +ipv4.routes "..."`) or a service that re-asserts.

**firewalld reverting zone changes.** A runtime-only `--zone=trusted
--change-interface` is undone by the next reload, and the symptom arrives much
later as `host unreachable - admin prohibited filter`. Use `--permanent` and
reload.

**A tool that is not in the node image.** `ping`, `openssl` and `etcdctl` are
absent. An "unreachable" result from `ping` means only that ping is missing; use
`curl` or bash's `/dev/tcp`. For etcd, `crictl exec` into the etcd static pod.
