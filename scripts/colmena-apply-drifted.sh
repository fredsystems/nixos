#!/usr/bin/env bash
#
# colmena-apply-drifted.sh -- deploy only the servers that are actually out of
# date, and refuse to deploy ahead of the published fleet manifest.
#
# WHAT IT DOES
#
#   1. Evaluates the toplevel store path colmena would deploy for every node.
#   2. Checks each of those paths against the published fleet manifest, and
#      stops if the manifest has not caught up (see THE MANIFEST GUARD below).
#   3. Asks each node over SSH what it is actually running.
#   4. Runs `colmena apply --on <nodes>` for just the ones that differ.
#
# Topology is read from `colmenaHive.deploymentConfig`, which is the same data
# colmena itself deploys from, so target hosts, ports and users cannot drift out
# of sync with the node table in flake/hosts/servers.nix.
#
# THE MANIFEST GUARD
#
# The fleet manifest is published by a workflow that runs AFTER a merge, and each
# host only compares itself against the manifest on a timer. Merge and deploy
# quickly and you land in a window where a host is running a closure the manifest
# has never heard of. The host cannot tell that apart from a hand-built WIP
# system on its own, so it reports a deploy state of `unknown` until the manifest
# publishes and it refetches.
#
# That window is harmless when the workflow is simply a couple of minutes behind.
# It is NOT harmless when the workflow has failed: then the manifest never catches
# up, drift detection for that host stays blind indefinitely, and the only signal
# is a NixOSDeployStateUnknown alert twelve hours later. This guard is what tells
# those two situations apart before you deploy rather than after.
#
# The check is per-host closure equality, not a commit comparison. That matters:
# a commit that does not change a given host's closure leaves the manifest still
# correct for it, so such a host is safe to deploy even though the manifest's
# recorded revision is older than HEAD. Comparing revisions would refuse those
# deploys for no reason.
#
# Local evaluation uses colmenaHive while the manifest is generated from
# nixosConfigurations. Those two are byte-identical by construction, and
# scripts/gen-fleet-manifest.sh refuses to publish if they ever stop being, so
# comparing one against the other is sound.
#
# WHY SSH RATHER THAN THE PROMETHEUS METRIC
#
# nixos_deploy_state would answer "who is drifted" in a single query, but it is
# only as fresh as each host's last timer run. A stale metric can report a host
# as current when it is not, and this script would then skip the one host that
# needed deploying. SSH is ground truth, and colmena needs it anyway.
#
# PER-NODE GOALS: WHY THERE ARE TWO DEPLOY PHASES
#
# Four independent reasons below (systemd changes, kernel changes, critical-
# unit restart, critical-process version change) make a live `switch` wrong
# for SOME nodes in a run, not all of them. A single
# `colmena apply` takes one goal for every target, so the only way to respect
# a per-node verdict is to invoke colmena twice:
#
#   phase 1   the held-back nodes, with the `boot` goal -- closure staged and
#             bootloader pointed at it, nothing activated, nothing restarted
#   phase 2   everything else, with the requested goal (`switch` by default)
#
# Held-back nodes keep running their old generation until you reboot them,
# which `--reboot` does. This is what replaced the original behaviour of
# refusing the WHOLE run: one risky node used to force every other node into
# `boot` too, so a reboot of the entire fleet was the price of one node's
# hazard.
#
# Phase 1 runs first deliberately. It activates nothing, so it cannot disturb
# phase 2; running it second would mean a phase-2 failure left the risky nodes
# with nothing staged at all.
#
# SYSTEMD CHANGES: NEVER RE-EXEC PID 1 ON A REMOTE NODE
#
# A deploy that changes systemd's own package -- the PID 1 binary, not any
# unit -- is staged with `boot`, unconditionally. Unit changes are not part of
# this rule; they are routine and handled by activation (and, for the few that
# matter to other nodes, by the critical-unit check below).
#
# The reason is that `switch` answers a systemd change by re-execing PID 1 in
# place, and a failed re-exec leaves systemd frozen -- alive but deaf to D-Bus,
# so nothing starts or stops and `reboot` hangs too, because reboot is itself a
# D-Bus call to PID 1. Recovering a frozen remote node means physically
# visiting it. The known mechanism is NixOS/nixpkgs#375376: on re-exec PID 1
# re-runs its generators, systemd-fstab-generator stat()s every fstab entry, a
# `hard` NFS mount whose server is unreachable blocks forever, the generator
# sandbox times out after 90s, and PID 1 gives up and freezes.
#
# This used to hold a node back only when it ALSO had live NFS/CIFS mounts.
# That second condition was both fragile and blind: it ran `findmnt -t nfs`,
# which does not see an `x-systemd.automount` share that is currently idle
# (findmnt reports it as `autofs`), so fredhub's /mnt/media -- still in fstab,
# still visited by the generator -- read as "no network mounts" and a systemd
# bump was switched live. A reboot reaches the new systemd with no re-exec at
# all, so the rule is now simply: systemd moves, the node is staged.
#
# "Changes" means the store path, which a glibc/stdenv mass rebuild moves even
# at an unchanged systemd version. That is deliberate: PID 1 re-execs either
# way, so it is the same risk.
#
# THE KERNEL
#
# A kernel cannot be switched into at all; `switch` installs it, reports
# success, and leaves the old one running -- so the node looks deployed while
# the kernel bump (often the whole point of the deploy, given the kernel is
# pinned to its own monthly cadence) is not live. The reboot is owed either
# way, so a node whose kernel or module tree changes is staged with `boot` and
# the reboot is made explicit rather than silently outstanding.
#
# The comparison is against /run/booted-system, not /run/current-system: the
# question is "what is the kernel actually running", and an earlier plain
# `switch` may already have moved current-system's kernel without a reboot.
# Modules are included because they change on their own when an out-of-tree
# module (nvrhub's NVIDIA driver) is rebuilt at the same kernel. What is
# compared is the SET of module packages the tree is assembled from -- the
# store references of /run/booted-system/kernel-modules -- not the tree's own
# store path. The tree is a buildEnv + depmod wrapper, so a mass rebuild moves
# its hash while every .ko inside stays byte-identical; comparing that hash
# flagged six nodes as owing a reboot with nothing to boot into.
#
# THE CRITICAL-UNIT HAZARD
#
# Some units are single points of failure for OTHER nodes' deploys. atticd is
# the binary cache every closure in the run is substituted from; AdGuard and
# Unbound are the DNS every later SSH in the run resolves through. Activation
# restarting one of those mid-run breaks the deploys that have not happened
# yet, and the failure surfaces on an innocent node rather than on the one
# that caused it.
#
# Which units those are is NOT a list in this script. Each is declared as
# `deployment.criticalUnits` next to the service that defines it, so moving
# atticd or DNS to a different host moves the protection with it and there is
# nothing here to update. See modules/base/deployment-meta.nix.
#
# The test is exact rather than heuristic: switch-to-configuration restarts a
# unit precisely when its unit file changed, so this compares the unit-file
# store path the node is running (/run/current-system/etc/systemd/system/<unit>)
# against the one the target closure evaluates to
# (config.systemd.units.<unit>.unit). Equal means activation will not touch it.
#
# THE CRITICAL-PROCESS HAZARD
#
# deployment.criticalProcesses -- in practice the compositor on a desktop --
# holds a node whose RUNNING instance of the package would move to a different
# version. No server declares one today; the rule is here because it lives in
# the shared library, not because this script special-cases it. See
# modules/base/deployment-meta.nix.
#
# SHARED WITH THE DESKTOP PREFLIGHT
#
# The probe, every hold rule above and the post-switch stale-process report
# live in scripts/lib/deploy-guard.sh, and the target side in
# flake/lib/deploy-facts.nix. scripts/switch-preflight.sh sources the same
# library for the local machine, so the two cannot drift apart. Change a rule
# THERE, not here.
#
# REBOOT MODE
#
# `--reboot` is the other half of the `boot` goal: it finds every node that
# owes a reboot -- its system profile points somewhere other than
# /run/current-system (a staged-but-not-activated generation), or the running
# generation carries a kernel other than the one the node booted (a kernel that
# was switched into live) -- and reboots them one at a time, waiting for each
# to come back BOOTED into its profile before touching the next. Nodes with critical units go first, so the cache and DNS are settled
# before anything else moves, and a node that fails to return aborts the rest
# rather than taking more of the fleet down with it.
#
# Usage:
#   scripts/colmena-apply-drifted.sh                 # guard, report, deploy
#   scripts/colmena-apply-drifted.sh --dry-run       # report only
#   scripts/colmena-apply-drifted.sh --reboot        # reboot staged nodes, in order
#   scripts/colmena-apply-drifted.sh --reboot --yes  # ...without confirming
#   scripts/colmena-apply-drifted.sh --wait          # poll for the manifest
#   scripts/colmena-apply-drifted.sh --force         # deploy despite the manifest guard
#   scripts/colmena-apply-drifted.sh -- boot         # stage every node; reboot to apply
#   scripts/colmena-apply-drifted.sh --allow-unsafe-switch     # switch despite a systemd change
#   scripts/colmena-apply-drifted.sh --allow-kernel-switch     # switch despite a kernel change
#   scripts/colmena-apply-drifted.sh --allow-critical-restart  # ignore the critical-unit hazard
#   scripts/colmena-apply-drifted.sh --allow-process-change    # switch despite a critical-process version change
#   scripts/colmena-apply-drifted.sh -- --verbose    # pass args to colmena
#
# Note: `--reboot` before `--` is this script's reboot mode. Colmena's own
# `--reboot` flag is still reachable as `-- --reboot`.

set -euo pipefail

MANIFEST_URL="https://raw.githubusercontent.com/fredsystems/nixos/fleet-manifest/manifest.json"

# How long --wait will poll for the manifest to catch up. The publishing workflow
# evaluates every host (~1 minute) on top of runner startup, so a few minutes is
# the normal case; ten minutes means something is wrong rather than slow.
WAIT_TIMEOUT=600
WAIT_INTERVAL=15

# How long --reboot waits for a single node to come back on its staged closure,
# and how often it checks. Generous: these are spinning-rust servers with a
# UEFI POST in front of them, and one of them is a VPS across the internet.
REBOOT_TIMEOUT=420
REBOOT_INTERVAL=10

DRY_RUN=0
FORCE=0
WAIT=0
ALLOW_UNSAFE_SWITCH=0
ALLOW_KERNEL_SWITCH=0
ALLOW_CRITICAL_RESTART=0
ALLOW_PROCESS_CHANGE=0
REBOOT_MODE=0
ASSUME_YES=0
COLMENA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --force) FORCE=1 ;;
        --wait) WAIT=1 ;;
        --allow-unsafe-switch) ALLOW_UNSAFE_SWITCH=1 ;;
        --allow-kernel-switch) ALLOW_KERNEL_SWITCH=1 ;;
        --allow-critical-restart) ALLOW_CRITICAL_RESTART=1 ;;
        --allow-process-change) ALLOW_PROCESS_CHANGE=1 ;;
        --reboot) REBOOT_MODE=1 ;;
        --yes | -y) ASSUME_YES=1 ;;
        --) shift; COLMENA_ARGS=("$@"); break ;;
        -h | --help)
            # Print the whole header block by structure rather than by line
            # number: a hardcoded range silently truncates the moment the header
            # grows, which it already had -- the `--` passthrough line was being
            # cut off.
            awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1 (use -- to pass args to colmena)" >&2
            exit 1
            ;;
    esac
    shift
done

# --reboot activates already-staged closures; it never builds, pushes or
# consults the manifest. Accepting deploy-only flags alongside it would imply
# they do something.
if [[ $REBOOT_MODE -eq 1 ]]; then
    reboot_conflict=""
    [[ $FORCE -eq 1 ]] && reboot_conflict="--force"
    [[ $WAIT -eq 1 ]] && reboot_conflict="--wait"
    [[ $ALLOW_UNSAFE_SWITCH -eq 1 ]] && reboot_conflict="--allow-unsafe-switch"
    [[ $ALLOW_KERNEL_SWITCH -eq 1 ]] && reboot_conflict="--allow-kernel-switch"
    [[ $ALLOW_CRITICAL_RESTART -eq 1 ]] && reboot_conflict="--allow-critical-restart"
    [[ $ALLOW_PROCESS_CHANGE -eq 1 ]] && reboot_conflict="--allow-process-change"
    if [[ -n "$reboot_conflict" ]]; then
        echo "error: $reboot_conflict has no meaning with --reboot (nothing is built or deployed)" >&2
        exit 1
    fi
    if [[ ${#COLMENA_ARGS[@]} -gt 0 ]]; then
        echo "error: --reboot does not run colmena, so it cannot forward: ${COLMENA_ARGS[*]}" >&2
        exit 1
    fi
fi

for tool in nix jq git ssh curl colmena timeout; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "error: required tool not on PATH: $tool" >&2
        exit 1
    }
done

cd "$(git rev-parse --show-toplevel)"

# shellcheck source=scripts/lib/deploy-guard.sh
source scripts/lib/deploy-guard.sh

if [[ -n "$(git status --porcelain)" ]]; then
    cat >&2 <<'EOF'
warning: the working tree is dirty.

  A dirty tree evaluates to closures that no commit produced, so the manifest
  cannot contain them and every host you deploy will report deploy state
  'unmanaged' until you deploy again from a clean tree. That is the drift check
  working correctly, not a false alarm.

EOF
fi

# stderr is kept out of stdout: nix prints "Using saved setting for
# 'extra-substituters = ...'" notices for this flake's nixConfig whenever the
# invoking user is not trusted, and folding those in would corrupt the JSON.
EVAL_STDERR="$(mktemp)"
trap 'rm -f "$EVAL_STDERR"' EXIT

# Captured before evaluation and re-checked immediately before `colmena apply`,
# so an edit landing mid-run cannot deploy closures this run never evaluated.
#
# The diff content is hashed, not just the porcelain file list. The list records
# THAT a file is dirty, not what is in it, so editing an already-dirty file left
# both identifiers identical -- missing precisely the case this guard exists to
# catch. `git diff HEAD` covers staged and unstaged changes to tracked files,
# which is exactly the set a flake evaluation can see; untracked files are
# invisible to Nix and cannot affect the result.
source_identity() {
    git rev-parse HEAD
    git status --porcelain
    git diff HEAD | sha256sum
}
SOURCE_ID_AT_EVAL="$(source_identity)"

# One evaluation for every node: flake/lib/deploy-facts.nix, the same
# function the desktop preflight evaluates. Evaluating the hive is the
# expensive part of this script (a full module-system evaluation per node), so
# everything any guard needs comes out of this single call.
#
# The flat {node: toplevel} and {node: critical} views are derived from it for
# the manifest guard's jq and the reboot ordering, which were written against
# those shapes.
echo "Evaluating what colmena would deploy..." >&2
if ! FACTS_JSON="$(nix eval --json '.#lib.deployFacts.colmena' 2>"$EVAL_STDERR")"; then
    printf 'error: failed to evaluate .#lib.deployFacts.colmena:\n%s\n' "$(cat "$EVAL_STDERR")" >&2
    exit 1
fi
EXPECTED_JSON="$(jq -c 'map_values(.toplevel)' <<<"$FACTS_JSON")"
CRITICAL_JSON="$(jq -c 'map_values(.critical)' <<<"$FACTS_JSON")"

# Names are interpolated into the remote probe script, so they are checked
# here rather than trusted.
for node in $(jq -r 'keys[]' <<<"$FACTS_JSON"); do
    if ! why="$(dg_validate_facts "$(jq -c --arg n "$node" '.[$n]' <<<"$FACTS_JSON")")"; then
        echo "error: $node: $why" >&2
        exit 1
    fi
done

if ! DEPLOY_JSON="$(nix eval --json '.#colmenaHive.deploymentConfig' 2>>"$EVAL_STDERR")"; then
    printf 'error: failed to evaluate colmenaHive deploymentConfig:\n%s\n' "$(cat "$EVAL_STDERR")" >&2
    exit 1
fi

mapfile -t NODES < <(jq -r 'keys[]' <<<"$EXPECTED_JSON")
if [[ ${#NODES[@]} -eq 0 ]]; then
    echo "error: colmenaHive has no nodes" >&2
    exit 1
fi
echo "Evaluated ${#NODES[@]} node(s)." >&2

# --- The remote probe -----------------------------------------------------
#
# One SSH session per node collects everything any later stage needs. The
# script itself is DG_PROBE_BODY from scripts/lib/deploy-guard.sh -- the same
# bytes switch-preflight.sh runs locally -- built per node by dg_probe_script.

# Facts object and probe script for one node.
node_facts() {
    jq -c --arg n "$1" '.[$n]' <<<"$FACTS_JSON"
}
node_probe_script() {
    local facts want=0
    facts="$(node_facts "$1")"
    [[ "$(jq '.processes | length' <<<"$facts")" -gt 0 ]] && want=1
    dg_probe_script "$(dg_fact_units "$facts")" "$want"
}

# Probe one node. Prints the key=value block on stdout; returns non-zero if the
# node could not be reached at all.
#
#   $1 host   $2 port   $3 user   $4 probe script (node_probe_script)
#   $5 attempts (optional, default 2)
#
# StrictHostKeyChecking is pinned to yes rather than left to the caller's
# ssh_config, and certainly not set to accept-new.
#
# This probe decides whether a host is skipped. An attacker able to spoof DNS
# or a route could present their own host key, answer with the expected closure
# path, and cause a genuinely drifted host to be classified as current --
# silently withholding a deploy, which is the one failure direction here that
# matters. Trust-on-first-use is therefore the wrong default, and relying on the
# ambient config is not enough either: a `StrictHostKeyChecking no` entry in
# ~/.ssh/config would silently defeat it.
#
# Every node is already in known_hosts because colmena connects to them, so an
# unknown key means something is wrong. It fails, the caller records the node as
# unreachable, and it gets reported rather than skipped.
#
# The outer timeout bounds the whole session, which ConnectTimeout does not: it
# only covers reaching the port. A host that accepts the connection and then
# wedges -- full disk, load spike, D-state -- would otherwise block the caller's
# loop forever and prevent every later node from being classified.
#
# Retried by default. A transient blip -- flaky mDNS for a .local name, a moment
# of packet loss -- otherwise demotes a host to unreachable and the run proceeds
# without it, withholding a deploy from a host that needed one. Observed in
# practice, so this is not hypothetical. --reboot's wait loop passes 1 attempt
# because it is already polling and expects failures while the node is down.
probe_node() {
    local host="$1" port="$2" user="$3" script="$4" attempts="${5:-2}"
    local attempt out

    for ((attempt = 1; attempt <= attempts; attempt++)); do
        # `/bin/sh -s` with the script on stdin, rather than passing it as a
        # command argument, for two reasons.
        #
        # The interpreter is pinned. `ssh host '<script>'` runs the script in
        # the account's LOGIN shell, which here is zsh -- and zsh does not
        # word-split unquoted parameter expansions. `for u in $CRITICAL_UNITS`
        # therefore ran exactly once with the whole list as a single word, and
        # every node with more than one critical unit reported "could not
        # compare" for all of them. Found by testing, not by reading: a node
        # with exactly one critical unit works either way, which is why the
        # first host tried looked fine.
        #
        # And it removes a layer of quoting. The script no longer has to
        # survive being embedded in a command line that ssh reassembles and a
        # remote shell re-parses.
        if out="$(
            timeout 30 ssh \
                -o BatchMode=yes \
                -o ConnectTimeout=10 \
                -o StrictHostKeyChecking=yes \
                -p "$port" "${user}@${host}" /bin/sh -s \
                2>/dev/null <<<"$script"
        )"; then
            printf '%s\n' "$out"
            return 0
        fi
        [[ "$attempt" -lt "$attempts" ]] && sleep 3
    done
    return 1
}

# Space-separated critical unit names for a node, in a stable order.
node_critical_units() {
    jq -r --arg n "$1" '(.[$n] // {}) | keys | join(" ")' <<<"$CRITICAL_JSON"
}

# --- Determine what each node is actually running -------------------------
#
# Done BEFORE the manifest guard, so the guard can be scoped to the nodes that
# are actually going to be deployed. Checking every evaluated node instead would
# refuse the whole run because some node that needs no deploy happens to have an
# unpublished closure -- blocking a safe deployment for an unrelated host.

DRIFTED=()
CURRENT=()
UNREACHABLE=()
SYSTEMD_HOLD=()
KERNEL_HOLD=()
CRITICAL_HOLD=()
CRITICAL_UNKNOWN=()
STAGED=()
STAGED_WHY=()

# The *_NODES arrays carry bare node names for the bucketing below, while the
# arrays above carry the human-readable explanation. Kept separate rather than
# parsing the node name back out of a message: the message format is for
# people and is expected to change, and re-parsing it would turn a wording
# tweak into a silent mis-bucketing.
SYSTEMD_HOLD_NODES=()
KERNEL_HOLD_NODES=()
CRITICAL_HOLD_NODES=()
PROCESS_HOLD=()
PROCESS_HOLD_NODES=()
PROCESS_INFO=()

# Parallel arrays indexed alongside NODES, so later stages (the reboot flow in
# particular) do not need a second round of SSH or jq to recover what the probe
# already learned. Bash 4 associative arrays would read better, but this script
# already avoids them elsewhere for portability.
PROBE_NODES=()
PROBE_RUNNING=()
PROBE_PROFILE=()

for node in "${NODES[@]}"; do
    host="$(jq -r --arg n "$node" '.[$n].targetHost // ""' <<<"$DEPLOY_JSON")"
    port="$(jq -r --arg n "$node" '.[$n].targetPort // 22' <<<"$DEPLOY_JSON")"
    user="$(jq -r --arg n "$node" '.[$n].targetUser // "root"' <<<"$DEPLOY_JSON")"

    if [[ -z "$host" ]]; then
        UNREACHABLE+=("$node (no targetHost)")
        continue
    fi

    if ! probe_out="$(probe_node "$host" "$port" "$user" "$(node_probe_script "$node")")"; then
        UNREACHABLE+=("$node ($host)")
        continue
    fi

    # Every rule lives in dg_classify (scripts/lib/deploy-guard.sh); this loop
    # only files its verdict into the buckets the rest of the script uses.
    dg_classify "$(node_facts "$node")" "$probe_out"

    if [[ "$DG_STATE" == noprobe ]]; then
        UNREACHABLE+=("$node ($host: probe returned no toplevel)")
        continue
    fi

    PROBE_NODES+=("$node")
    PROBE_RUNNING+=("$DG_RUNNING")
    PROBE_PROFILE+=("$DG_PROFILE")

    # Recorded regardless of drift: a node whose staged closure IS the
    # expected one looks current while still owing a reboot.
    if [[ -n "$DG_OWED" ]]; then
        STAGED+=("$node")
        STAGED_WHY+=("$node: $DG_OWED")
    fi

    if [[ "$DG_STATE" == current ]]; then
        CURRENT+=("$node")
        continue
    fi
    DRIFTED+=("$node")

    if [[ -n "$DG_HOLD_SYSTEMD" ]]; then
        SYSTEMD_HOLD+=("$node ($host): $DG_HOLD_SYSTEMD")
        SYSTEMD_HOLD_NODES+=("$node")
    fi
    if [[ -n "$DG_HOLD_KERNEL" ]]; then
        KERNEL_HOLD+=("$node ($host): $DG_HOLD_KERNEL")
        KERNEL_HOLD_NODES+=("$node")
    fi
    for entry in ${DG_HOLD_CRITICAL[@]+"${DG_HOLD_CRITICAL[@]}"}; do
        CRITICAL_HOLD+=("$node ($host): $entry")
        CRITICAL_HOLD_NODES+=("$node")
    done
    for entry in ${DG_CRITICAL_UNKNOWN[@]+"${DG_CRITICAL_UNKNOWN[@]}"}; do
        CRITICAL_UNKNOWN+=("$node ($host): $entry")
    done
    for entry in ${DG_HOLD_PROCESS[@]+"${DG_HOLD_PROCESS[@]}"}; do
        PROCESS_HOLD+=("$node ($host): $entry")
        PROCESS_HOLD_NODES+=("$node")
    done
    for entry in ${DG_INFO[@]+"${DG_INFO[@]}"}; do
        PROCESS_INFO+=("$node ($host): $entry")
    done
done

printf '\n%-12s %s\n' "current:" "${CURRENT[*]:-none}"
printf '%-12s %s\n' "to deploy:" "${DRIFTED[*]:-none}"
if [[ ${#STAGED[@]} -gt 0 ]]; then
    # Not a warning: this is the normal state between a held-back deploy and the
    # reboot that applies it. Reported because the alternative is a node sitting
    # on an unactivated generation indefinitely with nothing saying so.
    printf '%-12s %s\n' "reboot owed:" "${STAGED[*]}"
    for why in "${STAGED_WHY[@]}"; do
        printf '%-12s   %s\n' "" "$why"
    done
fi
if [[ ${#UNREACHABLE[@]} -gt 0 ]]; then
    # Reported rather than silently skipped: an unreachable node is one colmena
    # could not have deployed either, and treating it as "current" would quietly
    # leave it behind forever.
    printf '%-12s %s\n' "unreachable:" "${UNREACHABLE[*]}"
fi
echo

# --- Reboot mode ----------------------------------------------------------
#
# Deliberately placed after the probe loop and before everything else: it needs
# what the probe learned and nothing that follows. In particular it must be
# ahead of the "Nothing to deploy" exit, because a node that was staged with
# the expected closure and is waiting for a reboot is not drifted at all -- it
# would have exited there with a reboot still owed.
if [[ $REBOOT_MODE -eq 1 ]]; then
    if [[ ${#STAGED[@]} -eq 0 ]]; then
        echo "No node has a staged generation waiting for a reboot."
        [[ ${#UNREACHABLE[@]} -gt 0 ]] && echo "  (${#UNREACHABLE[@]} node(s) could not be probed -- see above.)"
        exit 0
    fi

    # Ordering is by criticality, not by a hardcoded host list. The nodes
    # carrying the cache and DNS come back first, so the rest of the fleet
    # reboots with its infrastructure already settled -- and because each node
    # is waited out before the next is touched, DNS is back before any later
    # node's name has to resolve.
    #
    # Order within each group is whatever jq's key order gives (alphabetical).
    # That is not load-bearing: nothing in the fleet depends on another
    # non-critical node being up to boot.
    REBOOT_ORDER=()
    for node in "${STAGED[@]}"; do
        [[ -n "$(node_critical_units "$node")" ]] && REBOOT_ORDER+=("$node")
    done
    for node in "${STAGED[@]}"; do
        [[ -z "$(node_critical_units "$node")" ]] && REBOOT_ORDER+=("$node")
    done

    echo "Reboot order: ${REBOOT_ORDER[*]}"
    echo "  One at a time; each must come back on its staged closure before the next is touched."
    echo

    if [[ $DRY_RUN -eq 1 ]]; then
        echo "would reboot, in order: ${REBOOT_ORDER[*]}"
        exit 0
    fi

    if [[ $ASSUME_YES -eq 0 ]]; then
        # `|| true`: read returns non-zero on EOF, which is what happens when
        # this is run non-interactively. Without it `set -e` would kill the
        # script there instead of falling through to the explicit refusal
        # below, and the exit status would say "crashed" rather than "declined".
        reply=""
        read -r -p "Reboot ${#REBOOT_ORDER[@]} node(s)? [y/N] " reply || true
        case "$reply" in
            y | Y | yes | YES) ;;
            *)
                echo "Aborted."
                exit 1
                ;;
        esac
    fi

    # Look up a value from the PROBE_* parallel arrays by node name.
    probe_lookup() {
        local want="$1" which="$2" i
        for i in "${!PROBE_NODES[@]}"; do
            if [[ "${PROBE_NODES[$i]}" == "$want" ]]; then
                case "$which" in
                    running) printf '%s' "${PROBE_RUNNING[$i]}" ;;
                    profile) printf '%s' "${PROBE_PROFILE[$i]}" ;;
                esac
                return 0
            fi
        done
        return 1
    }

    # Identifying "the machine running this script" two ways, because neither
    # alone is reliable. The hostname need not equal the node's attribute name
    # in the hive, and the closure comparison only works when this machine is
    # itself a NixOS host -- but a toplevel path contains the hostname, so a
    # match there is conclusive when it happens.
    self_host="$(hostname 2>/dev/null || echo "")"
    self_system="$(readlink -f /run/current-system 2>/dev/null || echo "")"
    REBOOTED=()
    SKIPPED_SELF=()

    for idx in "${!REBOOT_ORDER[@]}"; do
        node="${REBOOT_ORDER[$idx]}"
        host="$(jq -r --arg n "$node" '.[$n].targetHost // ""' <<<"$DEPLOY_JSON")"
        port="$(jq -r --arg n "$node" '.[$n].targetPort // 22' <<<"$DEPLOY_JSON")"
        user="$(jq -r --arg n "$node" '.[$n].targetUser // "root"' <<<"$DEPLOY_JSON")"
        script="$(node_probe_script "$node")"
        target="$(probe_lookup "$node" profile)"

        # Rebooting the machine running this script kills the script, and with
        # it the sequencing and the wait-for-return check for every node still
        # queued. Skipped and reported rather than attempted: fredhub has
        # allowLocalDeployment, so this is reachable.
        if [[ "$node" == "$self_host" ]] ||
            [[ -n "$self_system" && "$self_system" == "$(probe_lookup "$node" running)" ]]; then
            SKIPPED_SELF+=("$node")
            continue
        fi

        echo "==> $node: rebooting into $target"

        # --no-block so systemd acknowledges the request and returns instead of
        # holding the SSH session open through its own shutdown; without it the
        # connection dies mid-call and the exit status says nothing useful.
        # `|| true` regardless: a torn-down connection is the expected outcome
        # and the wait loop below is the real success test.
        timeout 30 ssh \
            -o BatchMode=yes \
            -o ConnectTimeout=10 \
            -o StrictHostKeyChecking=yes \
            -p "$port" "${user}@${host}" \
            'sudo systemctl --no-block reboot' >/dev/null 2>&1 || true

        deadline=$((SECONDS + REBOOT_TIMEOUT))
        back=0
        while [[ "$SECONDS" -lt "$deadline" ]]; do
            sleep "$REBOOT_INTERVAL"
            # One attempt, no retry: failures are expected while the node is
            # down, and probe_node's own retry would only slow the poll.
            if out="$(probe_node "$host" "$port" "$user" "$script" 1)"; then
                now="$(dg_probe_field "$out" booted)"
                # The node must be up AND have BOOTED the closure it was staged
                # with. Reachability alone is not enough: sshd answers well
                # before the check is meaningful, and if the node came back on
                # the OLD generation the reboot did not do what was asked.
                #
                # booted-system rather than current-system, because for a node
                # that owes a reboot only for its kernel, current-system
                # already equals the profile -- a check against it would pass
                # on the first poll, before the node had even gone down.
                # booted-system differs from the profile until a real boot.
                if [[ "$now" == "$target" ]]; then
                    back=1
                    break
                fi
            fi
        done

        if [[ "$back" -eq 0 ]]; then
            not_touched=("${REBOOT_ORDER[@]:idx+1}")
            {
                echo
                echo "error: $node did not come back on its staged closure within ${REBOOT_TIMEOUT}s."
                echo
                echo "  Remaining nodes have NOT been rebooted. Stopping here rather than"
                echo "  taking more of the fleet down while one node is in an unknown state."
                echo
                echo "  Rebooted so far: ${REBOOTED[*]:-none}"
                echo "  Not touched:     ${not_touched[*]:-none}"
                echo
                echo "  Check the console for that host before retrying."
            } >&2
            exit 1
        fi

        REBOOTED+=("$node")
        echo "    back up on the staged generation."
    done

    echo
    echo "Rebooted: ${REBOOTED[*]:-none}"
    if [[ ${#SKIPPED_SELF[@]} -gt 0 ]]; then
        {
            echo
            echo "NOTE: skipped ${SKIPPED_SELF[*]} -- that is the machine running this script."
            echo "  Reboot it yourself once you are done here:"
            echo "    sudo reboot"
        } >&2
    fi
    exit 0
fi

if [[ ${#DRIFTED[@]} -eq 0 ]]; then
    echo "Nothing to deploy."
    if [[ ${#STAGED[@]} -gt 0 ]]; then
        echo "  ${#STAGED[@]} node(s) still owe a reboot: scripts/colmena-apply-drifted.sh --reboot"
    fi
    exit 0
fi

# --- Manifest guard, scoped to the deployment targets ---------------------

# Prints the space-separated subset of the given nodes whose locally-evaluated
# closure is not the one the published manifest currently expects for them.
#
# $1 is the remaining seconds allowed for the fetch, so a --wait loop cannot
# exceed its deadline by however long curl decides to spend.
manifest_lagging_nodes() {
    local budget="$1" manifest
    [[ "$budget" -lt 1 ]] && budget=1

    manifest="$(curl -sfL --max-time "$budget" "$MANIFEST_URL" 2>/dev/null || echo "")"

    if [[ -z "$manifest" ]] || ! jq -e '.schema == 1' <<<"$manifest" >/dev/null 2>&1; then
        echo "__FETCH_FAILED__"
        return 0
    fi

    jq -rn \
        --argjson expected "$EXPECTED_JSON" \
        --argjson m "$manifest" \
        --arg targets "${DRIFTED[*]}" \
        '
        ($targets | split(" ")) as $t
        | $expected | to_entries
        | map(select(
            (.key | IN($t[]))
            and (($m.hosts[.key].history[0].toplevel // "") != .value)
          ) | .key)
        | join(" ")
        '
}

if [[ $FORCE -eq 1 ]]; then
    echo "Skipping the manifest guard (--force)." >&2
else
    # Deadline measured with SECONDS, not by summing sleeps: each fetch can also
    # consume wall-clock time, so accumulating only the sleeps let --wait run for
    # several times its stated timeout when every fetch was slow.
    DEADLINE=$((SECONDS + WAIT_TIMEOUT))
    LAGGING="$(manifest_lagging_nodes "$((DEADLINE - SECONDS))")"

    if [[ $WAIT -eq 1 && -n "$LAGGING" ]]; then
        echo "Manifest has not caught up yet; waiting up to ${WAIT_TIMEOUT}s..." >&2
        while [[ -n "$LAGGING" && "$SECONDS" -lt "$DEADLINE" ]]; do
            # Sleep no further than the deadline, then only fetch if budget
            # remains. Sleeping a fixed interval could overshoot and leave a
            # nonpositive budget, which the fetch clamped to 1s -- letting a
            # --wait run exceed WAIT_TIMEOUT by an extra request.
            remaining=$((DEADLINE - SECONDS))
            [[ "$remaining" -le 0 ]] && break
            sleep "$(( WAIT_INTERVAL < remaining ? WAIT_INTERVAL : remaining ))"

            remaining=$((DEADLINE - SECONDS))
            [[ "$remaining" -le 0 ]] && break
            LAGGING="$(manifest_lagging_nodes "$remaining")"
            [[ -z "$LAGGING" ]] && echo "Manifest caught up after $((WAIT_TIMEOUT - remaining))s." >&2
        done
    fi

    if [[ "$LAGGING" == "__FETCH_FAILED__" ]]; then
        cat >&2 <<EOF
error: could not fetch the fleet manifest.

  Deploying now would leave every host unable to determine its deploy state.
  Check network access to raw.githubusercontent.com, or pass --force if you
  accept that consequence.
EOF
        exit 1
    fi

    if [[ -n "$LAGGING" ]]; then
        cat >&2 <<EOF
error: the published manifest does not yet describe the closures you are about
       to deploy, for: $LAGGING

  Either the fleet-manifest workflow has not finished for the current commit, or
  it failed. Deploying now leaves those hosts reporting deploy state 'unknown'
  until it publishes; if it failed, that is indefinite.

  Check:  gh run list --workflow=fleet-manifest.yaml --limit 3
  Wait:   $0 --wait
  Ignore: $0 --force
EOF
        exit 1
    fi

    echo "Manifest matches the closures to be deployed." >&2
fi

# --- Deploy ---------------------------------------------------------------

# On host-key policy for the deployment itself: colmena opens its own SSH
# connections and this script cannot inject options into them, so it cannot
# extend the pinned StrictHostKeyChecking used by the probe above to `colmena
# apply`. What it does provide is that the target list only ever contains hosts
# whose key verified against known_hosts moments earlier in this same run -- a
# host that failed that check is in UNREACHABLE and is never passed on. That
# narrows the exposure to a key swapped between probe and deploy rather than
# eliminating it. Closing it properly belongs in ssh_config or an SSH host CA,
# which would cover every colmena invocation rather than only this wrapper.

# `nix eval` above and `colmena apply` below resolve the flake independently, so
# a worktree edit landing in between would deploy something this run never
# evaluated and the guard never checked. Re-checking the source identity closes
# that window: cheaper than snapshotting the tree, and it catches the realistic
# case of editing a file while the SSH probing was in progress.
SOURCE_ID_NOW="$(source_identity)"
if [[ "$SOURCE_ID_NOW" != "$SOURCE_ID_AT_EVAL" ]]; then
    cat >&2 <<'EOF'
error: the working tree changed while this run was in progress.

  The closures checked against the manifest are no longer the ones colmena would
  build. Re-run so the evaluation, the guard and the deployment all agree.
EOF
    exit 1
fi

# --- What goal did the caller actually ask for? ---------------------------
#
# colmena takes the goal as a POSITIONAL argument -- `colmena apply [OPTIONS]
# [GOAL]` -- not as `--goal <x>`. There is no `--goal` flag at all, so looking
# for one (as this did originally) never matched: passing `-- boot` was still
# refused, and the error message told the caller to run a `--goal boot` that
# colmena would reject outright.
#
# The goal is pulled OUT of the forwarded arguments rather than left in them,
# because the two deploy phases below use different goals and would otherwise
# each inherit the caller's. COLMENA_OPTS is everything else, forwarded to both.
#
# `--reboot` makes `boot` the default goal instead of `switch`.
#
# Caveat, unchanged from before: a goal-shaped token is recognised wherever it
# appears, so an option VALUE that happens to read `boot` would be mistaken for
# the goal. No colmena option takes such a value today.
colmena_goal=""
colmena_reboot=0
COLMENA_OPTS=()
for arg in ${COLMENA_ARGS[@]+"${COLMENA_ARGS[@]}"}; do
    case "$arg" in
        build | push | switch | boot | test | dry-activate | upload-keys)
            if [[ -z "$colmena_goal" ]]; then
                colmena_goal="$arg"
            else
                COLMENA_OPTS+=("$arg")
            fi
            ;;
        --reboot)
            colmena_reboot=1
            COLMENA_OPTS+=("$arg")
            ;;
        *) COLMENA_OPTS+=("$arg") ;;
    esac
done

if [[ -z "$colmena_goal" ]]; then
    colmena_goal=$([[ "$colmena_reboot" -eq 1 ]] && echo boot || echo switch)
fi

# --- Bucket the drifted nodes by what is safe to do to each ---------------
#
# Only `switch` and `test` activate on the running system. `boot`, `build`,
# `push`, `dry-activate` and `upload-keys` restart nothing and re-exec nothing,
# so no hold reason applies and every node goes in one bucket.
#
# `test` is treated as activating, but it is NOT auto-split: `test` means
# "activate without touching the bootloader", and quietly answering that with a
# `boot` goal would write a bootloader entry the caller explicitly declined.
# Held nodes under `test` are refused instead, which is the old behaviour.
goal_activates=0
case "$colmena_goal" in
    switch | test) goal_activates=1 ;;
    *) ;;
esac

# Is $1 an element of the remaining arguments?
contains() {
    local needle="$1" item
    shift
    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

# The hold reasons in force for this run: the goal activates and the reason's
# override flag is NOT set. Used both to decide the buckets and to explain
# them, so the explanation can never cite a reason the caller already
# overrode -- which would send the reader after the wrong flag.
SYSTEMD_ACTIVE=$((goal_activates == 1 && ALLOW_UNSAFE_SWITCH == 0))
KERNEL_ACTIVE=$((goal_activates == 1 && ALLOW_KERNEL_SWITCH == 0))
CRITICAL_ACTIVE=$((goal_activates == 1 && ALLOW_CRITICAL_RESTART == 0))
PROCESS_ACTIVE=$((goal_activates == 1 && ALLOW_PROCESS_CHANGE == 0))

STAGE_BUCKET=()
SWITCH_BUCKET=()
for node in "${DRIFTED[@]}"; do
    hold=0
    if [[ $SYSTEMD_ACTIVE -eq 1 ]] &&
        contains "$node" ${SYSTEMD_HOLD_NODES[@]+"${SYSTEMD_HOLD_NODES[@]}"}; then
        hold=1
    fi
    if [[ $KERNEL_ACTIVE -eq 1 ]] &&
        contains "$node" ${KERNEL_HOLD_NODES[@]+"${KERNEL_HOLD_NODES[@]}"}; then
        hold=1
    fi
    if [[ $CRITICAL_ACTIVE -eq 1 ]] &&
        contains "$node" ${CRITICAL_HOLD_NODES[@]+"${CRITICAL_HOLD_NODES[@]}"}; then
        hold=1
    fi
    if [[ $PROCESS_ACTIVE -eq 1 ]] &&
        contains "$node" ${PROCESS_HOLD_NODES[@]+"${PROCESS_HOLD_NODES[@]}"}; then
        hold=1
    fi
    if [[ $hold -eq 1 ]]; then
        STAGE_BUCKET+=("$node")
    else
        SWITCH_BUCKET+=("$node")
    fi
done

# Print the in-force reasons for the nodes in STAGE_BUCKET, one per line.
print_hold_reasons() {
    local entry
    if [[ $SYSTEMD_ACTIVE -eq 1 ]]; then
        for entry in ${SYSTEMD_HOLD[@]+"${SYSTEMD_HOLD[@]}"}; do
            contains "${entry%% *}" "${STAGE_BUCKET[@]}" && echo "  $entry"
        done
    fi
    if [[ $KERNEL_ACTIVE -eq 1 ]]; then
        for entry in ${KERNEL_HOLD[@]+"${KERNEL_HOLD[@]}"}; do
            contains "${entry%% *}" "${STAGE_BUCKET[@]}" && echo "  $entry"
        done
    fi
    if [[ $CRITICAL_ACTIVE -eq 1 ]]; then
        for entry in ${CRITICAL_HOLD[@]+"${CRITICAL_HOLD[@]}"}; do
            contains "${entry%% *}" "${STAGE_BUCKET[@]}" && echo "  $entry"
        done
    fi
    if [[ $PROCESS_ACTIVE -eq 1 ]]; then
        for entry in ${PROCESS_HOLD[@]+"${PROCESS_HOLD[@]}"}; do
            contains "${entry%% *}" "${STAGE_BUCKET[@]}" && echo "  $entry"
        done
    fi
    return 0
}

# `test` cannot be auto-split (see above), so a held node under `test` is a
# refusal, not a staging.
if [[ "$colmena_goal" == "test" && ${#STAGE_BUCKET[@]} -gt 0 ]]; then
    {
        echo "error: refusing to \`test\` nodes that are held back: ${STAGE_BUCKET[*]}"
        echo
        print_hold_reasons
        cat <<EOF

  \`test\` activates without touching the bootloader, so this script will not
  silently substitute the \`boot\` goal for it the way it does for \`switch\`.

  Either drop the explicit goal and let the default split handle it:

    scripts/colmena-apply-drifted.sh

  or override the specific reason you have judged acceptable:

    scripts/colmena-apply-drifted.sh --allow-unsafe-switch -- test
    scripts/colmena-apply-drifted.sh --allow-kernel-switch -- test
    scripts/colmena-apply-drifted.sh --allow-critical-restart -- test
    scripts/colmena-apply-drifted.sh --allow-process-change -- test
EOF
    } >&2
    exit 1
fi

# --- Report the verdict before acting on it -------------------------------

if [[ ${#STAGE_BUCKET[@]} -gt 0 ]]; then
    {
        echo "These nodes will be STAGED (\`boot\`), not switched -- they keep running"
        echo "their current generation until you reboot them:"
        echo
        print_hold_reasons
        echo
    } >&2
fi

# Overridden reasons are still reported. The override says "I accept this", not
# "do not tell me".
if [[ $ALLOW_UNSAFE_SWITCH -eq 1 && ${#SYSTEMD_HOLD[@]} -gt 0 && $goal_activates -eq 1 ]]; then
    {
        echo "warning: switching despite a systemd change (--allow-unsafe-switch):"
        for entry in "${SYSTEMD_HOLD[@]}"; do
            echo "  $entry"
        done
        echo "  PID 1 will be re-exec'd in place. A node that freezes on re-exec stops"
        echo "  answering both systemctl AND reboot, and needs physical access."
        echo "  See NixOS/nixpkgs#375376."
        echo
    } >&2
fi

if [[ $ALLOW_KERNEL_SWITCH -eq 1 && ${#KERNEL_HOLD[@]} -gt 0 && $goal_activates -eq 1 ]]; then
    {
        echo "warning: switching despite a kernel change (--allow-kernel-switch):"
        for entry in "${KERNEL_HOLD[@]}"; do
            echo "  $entry"
        done
        echo "  The new kernel is NOT live until these nodes reboot. They will be"
        echo "  reported as staged (booted kernel differs from the running"
        echo "  generation's), so \`$0 --reboot\` picks them up."
        echo
    } >&2
fi

if [[ $ALLOW_CRITICAL_RESTART -eq 1 && ${#CRITICAL_HOLD[@]} -gt 0 && $goal_activates -eq 1 ]]; then
    {
        echo "warning: proceeding despite critical-unit restarts (--allow-critical-restart):"
        for entry in "${CRITICAL_HOLD[@]}"; do
            echo "  $entry"
        done
        echo "  Other nodes in this same run substitute closures and resolve names"
        echo "  through those units. Failures on unrelated nodes are the expected"
        echo "  symptom if the restart lands mid-run."
        echo
    } >&2
fi

if [[ $ALLOW_PROCESS_CHANGE -eq 1 && ${#PROCESS_HOLD[@]} -gt 0 && $goal_activates -eq 1 ]]; then
    {
        echo "warning: switching despite a critical-process version change (--allow-process-change):"
        for entry in "${PROCESS_HOLD[@]}"; do
            echo "  $entry"
        done
        echo
    } >&2
fi

if [[ ${#PROCESS_INFO[@]} -gt 0 ]]; then
    {
        echo "note:"
        for entry in "${PROCESS_INFO[@]}"; do
            echo "  $entry"
        done
        echo
    } >&2
fi

if [[ ${#CRITICAL_UNKNOWN[@]} -gt 0 ]]; then
    {
        echo "warning: the critical-unit guard could not evaluate these nodes:"
        for entry in "${CRITICAL_UNKNOWN[@]}"; do
            echo "  $entry"
        done
        echo "  They are NOT known to be safe. The usual cause is a unit that exists in"
        echo "  the target closure but whose running counterpart could not be read."
        echo
    } >&2
fi

# --- Deploy, in up to two phases ------------------------------------------

# Comma-join a node list for colmena's --on.
join_targets() {
    local IFS=,
    echo "$*"
}

# Run one phase. Returns colmena's exit code.
#   $1 phase label (for the log line)   $2 goal   $3.. nodes
run_phase() {
    local label="$1" goal="$2" rc
    shift 2
    local targets
    targets="$(join_targets "$@")"

    # Built as an array rather than interpolated inline so an empty
    # COLMENA_OPTS does not print a double space, which reads like a missing
    # argument when you are copying the line back out to run it by hand.
    local shown=(colmena apply --on "$targets")
    shown+=(${COLMENA_OPTS[@]+"${COLMENA_OPTS[@]}"} "$goal")

    if [[ $DRY_RUN -eq 1 ]]; then
        echo "would run (${label}): ${shown[*]}"
        return 0
    fi

    echo
    echo "Running (${label}): ${shown[*]}"
    set +e
    colmena apply --on "$targets" ${COLMENA_OPTS[@]+"${COLMENA_OPTS[@]}"} "$goal"
    rc=$?
    set -e
    return "$rc"
}

COLMENA_RC=0

# Phase 1 first, deliberately. It activates nothing, so it cannot disturb
# phase 2; running it second would mean a phase-2 failure left the nodes with
# the real hazards carrying nothing staged at all.
if [[ ${#STAGE_BUCKET[@]} -gt 0 ]]; then
    # `|| COLMENA_RC=$?` rather than `if ! run_phase`: inside an `if !` branch
    # $? is the status of the negation (always 0), so colmena's real exit code
    # would be lost and re-raised as success.
    run_phase "stage" boot "${STAGE_BUCKET[@]}" || COLMENA_RC=$?
    if [[ $COLMENA_RC -ne 0 ]]; then
        {
            echo
            echo "error: the staging phase failed; the switch phase was not started."
            echo "  Nothing was activated on any node."
        } >&2
        exit "$COLMENA_RC"
    fi
fi

if [[ ${#SWITCH_BUCKET[@]} -gt 0 ]]; then
    run_phase "$colmena_goal" "$colmena_goal" "${SWITCH_BUCKET[@]}" || COLMENA_RC=$?
fi

if [[ $DRY_RUN -eq 1 ]]; then
    exit 0
fi

# --- Stale processes on the deployed nodes -------------------------------
#
# What is still running a binary from before this switch: daemons activation
# reloaded rather than restarted (NetworkManager, by design -- see
# features/common/system/default.nix), and anything in a user session.
# Nothing is held for these; they are what is left to restart. The scan and
# the report are dg_scan_script / dg_scan_report, the same code
# switch-preflight.sh --deferred runs locally.
#
# Scoped to the nodes that were actually activated. A staged node's
# /run/current-system is untouched, so the scan could only produce noise --
# noise that reads as an all-clear for a node whose update is not applied.
if [[ $COLMENA_RC -eq 0 && ${#SWITCH_BUCKET[@]} -gt 0 && $goal_activates -eq 1 ]]; then
    scan_file="$(mktemp)"
    for node in "${SWITCH_BUCKET[@]}"; do
        host="$(jq -r --arg n "$node" '.[$n].targetHost // ""' <<<"$DEPLOY_JSON")"
        port="$(jq -r --arg n "$node" '.[$n].targetPort // 22' <<<"$DEPLOY_JSON")"
        user="$(jq -r --arg n "$node" '.[$n].targetUser // "root"' <<<"$DEPLOY_JSON")"
        [[ -n "$host" ]] || continue

        # Root on the node, via the same non-interactive sudo colmena's own
        # activation already relies on: /proc/<pid>/exe of another user's
        # process (every system daemon, for targetUser=fred) is unreadable
        # otherwise, and the report would rightly call itself incomplete.
        #
        # Straight to a file: the scan carries the node's whole closure, and
        # holding that in a shell variable trips "Argument list too long" on
        # the next exec (see dg_scan_report). `|| true` because a failed
        # session is reported by dg_scan_report as incomplete, not ignored.
        as_root=(/bin/sh -s)
        [[ "$user" == root ]] || as_root=(sudo -n /bin/sh -s)
        : >"$scan_file"
        timeout 60 ssh \
            -o BatchMode=yes \
            -o ConnectTimeout=10 \
            -o StrictHostKeyChecking=yes \
            -p "$port" "${user}@${host}" "${as_root[@]}" \
            >"$scan_file" 2>/dev/null <<<"$(dg_scan_script)" || true

        set +e
        report="$(dg_scan_report "$scan_file")"
        scan_rc=$?
        set -e
        # 0 is "nothing stale": not worth a line per clean node.
        [[ $scan_rc -eq 0 ]] && continue
        {
            echo
            echo "==> $node:"
            while IFS= read -r line; do
                printf '  %s\n' "$line"
            done <<<"$report"
        } >&2
    done
    rm -f "$scan_file"
fi

# --- What is still owed ---------------------------------------------------
#
# Loud and last. A staged node reports success from colmena while still running
# its old generation, so without this the run ends looking complete when part
# of the fleet has not applied anything.
if [[ ${#STAGE_BUCKET[@]} -gt 0 && $COLMENA_RC -eq 0 ]]; then
    cat >&2 <<EOF

ACTION REQUIRED: ${#STAGE_BUCKET[@]} node(s) were staged, not switched:

  ${STAGE_BUCKET[*]}

  They are still running their previous generation. The new one is built,
  pushed and set as the bootloader default, so a reboot is all that is left --
  and a reboot reaches it without re-execing a running PID 1 and without
  restarting a critical unit underneath an in-flight deploy.

  When you are ready:

    $0 --reboot

  That reboots them one at a time, cache and DNS first, waiting for each to
  come back on its staged closure before touching the next.
EOF
fi

exit "$COLMENA_RC"
