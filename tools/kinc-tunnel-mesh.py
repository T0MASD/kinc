#!/usr/bin/env python3
"""Render the WireGuard material for every node of a multi-host kinc cluster.

A node's tunnel address is its identity: it becomes both node-ip and, for a
control plane, advertiseAddress. Every node therefore needs a route to every
other node's tunnel address, which means a full mesh - hub-and-spoke would
leave worker-to-worker pod traffic with nowhere to go, since WireGuard does not
relay between peers.

Endpoint selection is the only part that depends on where a node runs:
  * a peer on another machine is reached at that machine's routable address and
    its published UDP port, so only machines that publish one can be dialled;
  * a peer on the same machine is reached at its static address on the shared
    podman network, which is why workers are pinned rather than left to podman.
At least one side of every pair must be dialable; a node with no endpoint for a
peer relies on that peer dialling in and keepalive holding the path open.
"""
import json, subprocess, sys, os

def keypair():
    priv = subprocess.run(["wg", "genkey"], capture_output=True, text=True,
                          check=True).stdout.strip()
    pub = subprocess.run(["wg", "pubkey"], input=priv, capture_output=True,
                         text=True, check=True).stdout.strip()
    return priv, pub

def main(spec_path, outdir):
    spec = json.load(open(spec_path))
    nodes = spec["nodes"]
    for n in nodes:
        n["priv"], n["pub"] = keypair()

    os.makedirs(outdir, exist_ok=True)
    for n in nodes:
        d = os.path.join(outdir, n["name"])
        os.makedirs(d, exist_ok=True)
        open(os.path.join(d, "private"), "w").write(n["priv"] + "\n")
        open(os.path.join(d, "public"), "w").write(n["pub"] + "\n")
        open(os.path.join(d, "address"), "w").write(n["wg"] + "\n")

        peers = []
        for p in nodes:
            if p["name"] == n["name"]:
                continue
            if p["machine"] == n["machine"]:
                # same machine: reach it directly on the shared podman network
                ep = "%s:51820" % p["podman"] if p.get("podman") else ""
            else:
                # another machine: only reachable if it publishes the port
                ep = "%s:51820" % p["host"] if p.get("publishes") else ""
            peers.append("%s %s/32 %s" % (p["pub"], p["wg"], ep))
        open(os.path.join(d, "peers"), "w").write("\n".join(peers) + "\n")

    # Report the mesh so the shape is visible before anything is deployed.
    print("  %d nodes across %d machines" %
          (len(nodes), len({n["machine"] for n in nodes})))
    for n in nodes:
        reach = sum(1 for l in open(os.path.join(outdir, n["name"], "peers"))
                    if l.strip() and len(l.split()) == 3)
        print("    %-22s wg=%-10s machine=%-16s peers=%d dialable=%d"
              % (n["name"], n["wg"], n["machine"], len(nodes) - 1, reach))
    # Every pair must be dialable from at least one side.
    bad = []
    for a in nodes:
        for b in nodes:
            if a["name"] >= b["name"]:
                continue
            def can(x, y):
                if x["machine"] == y["machine"]:
                    return bool(y.get("podman"))
                return bool(y.get("publishes"))
            if not can(a, b) and not can(b, a):
                bad.append("%s <-> %s" % (a["name"], b["name"]))
    if bad:
        print("  UNREACHABLE PAIRS: " + ", ".join(bad))
        sys.exit(1)
    print("  every pair is dialable from at least one side")

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
