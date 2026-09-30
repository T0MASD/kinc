#!/usr/bin/env bash
# Collects everything needed to diagnose a kinc cluster after the fact, for each
# cluster named, into artifacts/diagnostics/<cluster>/.
#
# Usage: ci-collect-diagnostics.sh <cluster> [more clusters]
#
# Collection is best-effort on purpose: it runs with `if: always()`, usually
# because something already failed, and a missing file must not stop the rest
# being gathered. That is the one place suppressing an error is right - it is
# not a check, and nothing downstream reads its result as a verdict.
#
# What it gathers is chosen from what actually went wrong in this repo:
# component logs (a Pod can be Running and useless), Antrea's own datapath view
# (asserted live by the gates and otherwise lost), and host state (module
# loading, mount propagation and quadlet contents have each been the cause).
set -uo pipefail

# shellcheck source=tools/lib-component-logs.sh
. "$(dirname "$0")/lib-component-logs.sh"

collect() {
  local cluster="$1"
  local node="kinc-${cluster}-control-plane"
  local out="artifacts/diagnostics/${cluster}"
  local kubeconfig="${HOME}/.kube/kinc-${cluster}-config"

  echo "=== ${cluster} ==="
  mkdir -p "$out"/{cluster,componentlogs,antrea,nodes}

  # --- cluster state -------------------------------------------------------
  # A kubeconfig carries a client certificate, so it is written outside the
  # artifact tree: these are uploaded, and a throwaway cluster's credentials are
  # still credentials.
  if [ -f "$kubeconfig" ]; then
    export KUBECONFIG="$kubeconfig"
  elif [ -f "$HOME/.kube/config" ]; then
    export KUBECONFIG="$HOME/.kube/config"
  else
    local tmp; tmp=$(mktemp)
    podman exec "$node" cat /etc/kubernetes/admin.conf > "$tmp" 2>/dev/null
    sed -i "s|server: https://.*:6443|server: https://127.0.0.1:$(podman inspect "$node" \
      --format '{{range $p, $c := .NetworkSettings.Ports}}{{range $c}}{{.HostPort}}{{end}}{{end}}' 2>/dev/null)|g" \
      "$tmp" 2>/dev/null
    export KUBECONFIG="$tmp"
  fi

  kubectl get nodes -o wide            > "$out/cluster/nodes.txt"        2>&1
  kubectl get pods -A -o wide          > "$out/cluster/pods.txt"         2>&1
  kubectl get events -A --sort-by=.lastTimestamp > "$out/cluster/events.txt" 2>&1
  kubectl get all -A                   > "$out/cluster/all.txt"          2>&1
  kubectl get pv,pvc,storageclass -A   > "$out/cluster/storage.txt"      2>&1

  # Anything not Running or Succeeded, described. A pod listing says a pod is
  # wrong; describe says why.
  kubectl get pods -A --no-headers 2>/dev/null \
    | awk '$4!="Running" && $4!="Completed" {print $1" "$2}' \
    | while read -r ns name; do
        [ -z "$ns" ] && continue
        echo "### $ns/$name"
        kubectl -n "$ns" describe pod "$name" 2>&1
      done > "$out/cluster/describe-unhealthy.txt"

  # --- component logs ------------------------------------------------------
  # Straight off the node's filesystem, where the CRI writes them, rather than
  # through `kubectl logs`. Three reasons, all of which have bitten:
  #
  #   - `kubectl logs` streams from the kubelet on :10250, and the kubelet logs
  #     an error every time such a connection closes. Collecting that way writes
  #     into the journal being collected.
  #   - it needs a working API server, which is not a safe assumption in the
  #     runs where these logs matter most.
  #   - the old call passed --tail=2000, so the start of a long log - where a
  #     bootstrap failure lives - was the part thrown away.
  #
  # Restarts come along for free: the CRI keeps 0.log, 1.log and so on, and all
  # of them are read. This capture is also what the gate and the summary parse
  # after teardown, so what they judge is exactly what was archived.
  # Facts that only exist while the cluster does, written down for whatever
  # reads the artifact later. The store path is here because two nodes sharing
  # one is the fault that made a container report an empty rootfs, and after
  # teardown there is nothing left to ask.
  {
    for n in $(kinc_nodes "$cluster"); do
      started=$(podman inspect "$n" 2>/dev/null | jq -r '.[0].State.StartedAt')
      store=$(podman inspect "$n" 2>/dev/null \
              | jq -r '.[0].Mounts[] | select(.Destination=="/root/.local/share/containers/storage") | .Source')
      age=$(( $(date +%s) - $(date -d "$started" +%s 2>/dev/null || echo 0) ))
      echo "${n}	${age}	${store:-none}"
    done
  } > "$out/nodes.tsv" 2>/dev/null

  # Pods and nodes into one directory, because they are analysed together:
  # the summary and the gate both read every file here as one component's log.
  # A node's journal belongs in that set - a sandbox that was never created has
  # no Pod log, and the kubelet's account of why is the only record of it.
  mkdir -p "$out/componentlogs"
  kinc_capture_pod_logs  "$out/componentlogs" "$cluster"
  echo "  pod logs: $(ls "$out/componentlogs" 2>/dev/null | wc -l) captured, ${KINC_UNREAD:-0} unreadable"
  kinc_capture_node_logs "$out/componentlogs" "$cluster"

  # --- Antrea's own view ---------------------------------------------------
  # The gates ask antctl these questions and then discard the answers, so a red
  # run loses the evidence that a green one prints.
  for agent in $(kubectl -n kube-system get pod -l app=antrea,component=antrea-agent \
                 -o name 2>/dev/null); do
    short="${agent##*/}"
    kubectl -n kube-system exec "$agent" -c antrea-agent -- antctl get agentinfo -o json \
      > "$out/antrea/${short}.agentinfo.json" 2>&1
    kubectl -n kube-system exec "$agent" -c antrea-agent -- antctl get podinterface -o json \
      > "$out/antrea/${short}.podinterface.json" 2>&1
    kubectl -n kube-system exec "$agent" -c antrea-agent -- antctl get ovsflows \
      > "$out/antrea/${short}.ovsflows.txt" 2>&1
  done
  kubectl -n kube-system get pod -l app=antrea -o wide > "$out/antrea/pods.txt" 2>&1

  # --- per node ------------------------------------------------------------
  for n in $(podman ps --format '{{.Names}}' 2>/dev/null | grep "^kinc-${cluster}-" || true); do
    d="$out/nodes/$n"; mkdir -p "$d"
    # --no-legend, so the file is unit rows and nothing else: with the header
    # and the "N loaded units listed." footer, a healthy node's file is four
    # non-empty lines that have to be parsed to learn they mean "none".
    podman exec "$n" systemctl list-units --state=failed --no-legend --plain --no-pager \
      > "$d/failed-units.txt" 2>&1
    podman exec "$n" systemctl status kinc-preflight kubeadm-init kinc-postinit crio kubelet \
      --no-pager > "$d/unit-status.txt" 2>&1
    podman exec "$n" journalctl --no-pager --boot > "$d/journal.txt" 2>&1

    # kubelet and CRI-O again, one file each, plus the error lines on their own.
    #
    # Both are already inside journal.txt, which is the problem: it is the whole
    # boot for every unit, and a kubelet question asked of a file that size is a
    # question nobody asks. The node's own view of why a pod never started lives
    # here and nowhere else - no Pod log exists for a sandbox that was never
    # created - so it is worth having at the path someone would guess.
    #
    # klog writes E and F at the start of a line, so errors.log is every line
    # any unit logged above warning, in order, across the whole boot.
    for u in kubelet crio; do
      podman exec "$n" journalctl -u "$u" --no-pager --boot > "$d/${u}.log" 2>&1
    done
    podman exec "$n" journalctl --no-pager --boot 2>/dev/null \
      | grep -E ' [EF][0-9]{4} ' > "$d/errors.log"
    echo "  ${n}: $(wc -l < "$d/errors.log") line(s) above warning"

    # kubeadm writes to a file, not the journal.
    podman exec "$n" sh -c 'cat /var/log/kinc/*.log' > "$d/kinc-scripts.log" 2>&1

    # What the crun wrapper was asked to do and what it did. It sits between
    # the kubelet's intent and the container that results, and nothing else
    # records that step: a create that fails reports only the kernel's refusal,
    # not whether the rewrite meant to prevent it ran. On tmpfs inside the node,
    # so it is gone the moment the container is, which is why it is taken here.
    podman exec "$n" sh -c 'cat /tmp/crun-debug.log' > "$d/crun-wrapper.log" 2>/dev/null
    [ -s "$d/crun-wrapper.log" ] || rm -f "$d/crun-wrapper.log"
    podman inspect "$n" > "$d/inspect.json" 2>&1
  done

  # --- host ----------------------------------------------------------------
  # Module loading, mount propagation and quadlet contents have each been the
  # root cause of a failure here, and none of them are visible from inside.
  local h="$out/host"; mkdir -p "$h"
  cp ~/.config/containers/systemd/kinc-${cluster}-*.* "$h/" 2>/dev/null
  systemctl --user list-units --all "kinc-${cluster}-*" --no-pager > "$h/user-units.txt" 2>&1
  podman ps -a                > "$h/podman-ps.txt"       2>&1
  podman network ls           > "$h/podman-networks.txt" 2>&1
  podman volume ls            > "$h/podman-volumes.txt"  2>&1
  { echo "# kernel modules"; for m in openvswitch geneve; do
      printf '%s: ' "$m"
      if [ -d "/sys/module/$m" ]; then echo loaded
      elif grep -qw "$m" "/lib/modules/$(uname -r)/modules.builtin" 2>/dev/null; then echo builtin
      else echo MISSING; fi
    done
    # Each node's store, since every node has its own.
    #
    # This asked about $HOME/.local/share/kinc/storage, the one shared store
    # that existed before the stores were split per node. That path stopped
    # existing with the split, findmnt printed nothing for it, and the section
    # has been empty in every run since - a diagnostic reporting nothing about
    # the thing its own comment says has caused a failure here.
    echo "# mount propagation"
    for store in "$HOME/.local/share/kinc/${cluster}/stores"/*; do
        [ -d "$store" ] || continue
        printf '%s: %s\n' "$(basename "$store")" \
            "$(findmnt -no TARGET,PROPAGATION --target "$store" 2>/dev/null || echo unknown)"
    done
    echo "# kernel"; uname -a
  } > "$h/host-contract.txt" 2>&1

  echo "  files: $(find "$out" -type f | wc -l)"
}

echo "=== Collecting diagnostics ==="
for c in "$@"; do collect "$c"; done
echo "✅ Diagnostics collected"
