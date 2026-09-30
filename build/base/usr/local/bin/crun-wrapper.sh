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
#
# Every invocation is recorded in /var/log/crun-wrapper.log: what CRI-O asked
# for, and what was done to the spec. This is the only account of a step that
# happens between the kubelet's intent and the container that results, so when a
# create fails it is the difference between "Permission denied" and knowing
# which spec was rewritten and whether the rewrite worked.
#
# Under /var, which is a volume, rather than /tmp, which is tmpfs. On tmpfs it
# was RAM, and it was erased by the restart that a node lifecycle verb performs
# - so after `kinc node start` the wrapper's account of what it did before the
# restart was gone, at the moment a container failing to create is exactly what
# you are trying to explain. The volume is removed by cleanup.sh with the rest
# of the cluster, so a rebuilt cluster of the same name starts with an empty
# log rather than inheriting the last one's.
#
# Persistent means it needs a bound. It grows with container churn - about 12K
# for a two-node bootstrap, and roughly 2MiB a day on an idle cluster, since
# every exec probe is another invocation - so it is rotated once at 16MiB and
# the previous file kept, which is two files and at most 32MiB.
#
# ci-collect-diagnostics.sh copies it into the per-node diagnostics, so it is in
# the artifacts of every CI run.
set -euo pipefail

DEBUG_LOG=/var/log/crun-wrapper.log

# Rotate before writing, never fatally. Checked once per invocation rather than
# per line: a stat is cheap and this runs on the path that creates every
# container in the cluster.
if [ -f "$DEBUG_LOG" ]; then
    size=$(stat -c %s "$DEBUG_LOG" 2>/dev/null || echo 0)
    if [ "$size" -gt $(( 16 * 1024 * 1024 )) ]; then
        mv -f "$DEBUG_LOG" "${DEBUG_LOG}.1" 2>/dev/null || true
    fi
fi

# Always succeeds, deliberately. This runs under `set -e` on the path that
# creates every container in the cluster, so a full disk or an unwritable
# /var/log must not be able to stop one starting. The record is worth having;
# it is not worth a node that cannot run pods.
note() {
    # The guard is what makes it non-fatal: under `set -e` a failed redirection
    # aborts the function before any `return 0` could run, and the container
    # never gets created. Verified by pointing DEBUG_LOG at a directory that
    # does not exist - without this, crun is never reached. That is also the
    # fallback if /var/log is somehow absent: no record, never a node that
    # cannot start pods.
    # RFC 3339 with nanoseconds and a literal Z, matching the API audit log and
    # the CRI's pod logs exactly, so all three merge on one timeline without
    # being reformatted. Not `date -Is`, which stops at seconds - container
    # creates arrive in bursts and whole seconds lose their order. Not
    # `date -Ins` either: it writes the fraction with a comma, which is not
    # RFC 3339 and does not sort against the others.
    if ! printf '%s: %s\n' "$(date -u +%FT%T.%9NZ)" "$*" >> "$DEBUG_LOG" 2>/dev/null; then
        return 0
    fi
}

note "called with: $*"

if [[ "$*" == *"create"* ]]; then
    bundle=""
    for ((i = 1; i <= $#; i++)); do
        if [[ "${!i}" == "--bundle" ]]; then
            j=$((i + 1))
            bundle="${!j}"
            break
        fi
    done

    if [[ -z "$bundle" ]]; then
        note "create with no --bundle, nothing to rewrite"
    elif [[ ! -f "$bundle/config.json" ]]; then
        note "create with no config.json under ${bundle}"
    fi

    if [[ -n "$bundle" && -f "$bundle/config.json" ]]; then
        if jq -e '.process.oomScoreAdj' "$bundle/config.json" >/dev/null 2>&1; then
            want=$(jq -r '.process.oomScoreAdj' "$bundle/config.json")

            # Only what cannot be set. Lowering oom_score_adj below the floor
            # this process inherited is what needs CAP_SYS_RESOURCE in the
            # initial user namespace; raising it is always allowed.
            #
            # Stripping everything, as this used to, removed the positive
            # values as well - the kubelet asks for 997, 998 and 1000 on
            # Burstable and BestEffort pods precisely so they are killed before
            # anything else. With those gone every pod sat at the inherited
            # floor and the cluster had no OOM ordering at all: under memory
            # pressure the kernel was as likely to take etcd as a BestEffort
            # job. Leaving them alone costs nothing, because they succeed.
            floor=$(cat /proc/self/oom_score_adj 2>/dev/null || echo 0)
            if [[ "$want" -ge "$floor" ]]; then
                note "kept oomScoreAdj=${want} (>= floor ${floor}, crun can set it)"
                exec /usr/bin/crun.orig "$@"
            fi
            # Written to a temporary file and moved, so a failed jq leaves the
            # original spec intact rather than a truncated one.
            if jq 'del(.process.oomScoreAdj)' "$bundle/config.json" > "$bundle/config.json.tmp"; then
                mv "$bundle/config.json.tmp" "$bundle/config.json"
                note "stripped oomScoreAdj=${want} from ${bundle}/config.json"
            else
                note "FAILED to strip oomScoreAdj=${want} from ${bundle}/config.json"
                rm -f "$bundle/config.json.tmp"
                # Say so, because the alternative is silence followed by a
                # container that will not create. crun rejects the spec this
                # left in place, and CRI-O reports only "write to
                # /proc/self/oom_score_adj: Permission denied" - true, and no
                # help in finding the rewrite that was supposed to prevent it.
                #
                # The journal rather than a file: journald bounds it, and the
                # diagnostics collector already takes the whole boot journal,
                # so this reaches a CI artifact without anything being wired up
                # for it. `journalctl -t crun-wrapper` on a node, or grep the
                # collected journal.txt.
                logger -t crun-wrapper -p daemon.err \
                    "failed to strip oomScoreAdj from ${bundle}/config.json; crun will refuse it"
            fi
        fi
    fi
fi

exec /usr/bin/crun.orig "$@"
