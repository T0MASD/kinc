#!/bin/bash
# Strip oomScoreAdj from OCI specs before handing them to crun.
#
# Rootless cannot lower oom_score_adj below the floor its session inherited:
# fs/proc/base.c checks capable(CAP_SYS_RESOURCE), which is against the initial
# user namespace, so no capability a rootless container holds satisfies it.
# crun does not treat that as advisory - it fails the create:
#
#   Container creation error: write to `/proc/self/oom_score_adj`: Permission denied
#
# The kubelet asks for -997 on Guaranteed pods and -999 on the control plane's
# static ones, so without this the API server never starts and the cluster does
# not come up. Verified by removing the wrapper: etcd, kube-apiserver and
# kube-controller-manager all fail to create, and kubeadm times out waiting for
# an API server that never arrives.
#
# It removes nothing else. Earlier versions also deleted process.user, which
# made every container run as root whatever its image or securityContext said,
# and deleted capabilities from any spec whose JSON happened to contain the
# string "helper" - which matches local-path's helper pod and anything else
# that mentions the word. Neither was needed to start a cluster.
set -euo pipefail

if [[ "$*" == *"create"* ]]; then
    bundle=""
    for ((i = 1; i <= $#; i++)); do
        if [[ "${!i}" == "--bundle" ]]; then
            j=$((i + 1))
            bundle="${!j}"
            break
        fi
    done

    if [[ -n "$bundle" && -f "$bundle/config.json" ]]; then
        if jq -e '.process.oomScoreAdj' "$bundle/config.json" >/dev/null 2>&1; then
            # Written to a temporary file and moved, so a failed jq leaves the
            # original spec intact rather than a truncated one.
            if jq 'del(.process.oomScoreAdj)' "$bundle/config.json" > "$bundle/config.json.tmp"; then
                mv "$bundle/config.json.tmp" "$bundle/config.json"
            else
                rm -f "$bundle/config.json.tmp"
            fi
        fi
    fi
fi

exec /usr/bin/crun.orig "$@"
