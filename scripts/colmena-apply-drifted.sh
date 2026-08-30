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
# THE PID 1 FREEZE GUARD
#
# A `switch` that re-execs PID 1 while the node has network filesystems mounted
# can leave systemd frozen -- alive but deaf to D-Bus, so nothing starts or
# stops and `reboot` hangs too, because reboot is itself a D-Bus call to PID 1.
# The mechanism is NixOS/nixpkgs#375376: on re-exec PID 1 re-runs its
# generators, systemd-fstab-generator stat()s every fstab entry, a `hard` NFS
# mount whose server is unreachable blocks forever, the generator sandbox times
# out after 90s, and PID 1 gives up and freezes.
#
# The probe below collects both preconditions per node while it is already
# connected: whether the deploy changes systemd's store path (which is what
# triggers the re-exec, and which a glibc/stdenv mass rebuild causes even at an
# unchanged systemd version), and whether the node has live NFS/CIFS mounts.
# Nodes with both are refused rather than warned about, because recovering a
# frozen remote node means physically visiting it. `--goal boot` plus a reboot
# reaches the same generation without re-execing a running PID 1.
#
# Usage:
#   scripts/colmena-apply-drifted.sh                 # guard, report, deploy
#   scripts/colmena-apply-drifted.sh --dry-run       # report only
#   scripts/colmena-apply-drifted.sh --wait          # poll for the manifest
#   scripts/colmena-apply-drifted.sh --force         # deploy despite the guard
#   scripts/colmena-apply-drifted.sh -- --goal boot  # stage; reboot to apply
#   scripts/colmena-apply-drifted.sh --allow-unsafe-switch
#   scripts/colmena-apply-drifted.sh -- --verbose    # pass args to colmena

set -euo pipefail

MANIFEST_URL="https://raw.githubusercontent.com/fredsystems/nixos/fleet-manifest/manifest.json"

# How long --wait will poll for the manifest to catch up. The publishing workflow
# evaluates every host (~1 minute) on top of runner startup, so a few minutes is
# the normal case; ten minutes means something is wrong rather than slow.
WAIT_TIMEOUT=600
WAIT_INTERVAL=15

DRY_RUN=0
FORCE=0
WAIT=0
ALLOW_UNSAFE_SWITCH=0
COLMENA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --force) FORCE=1 ;;
        --wait) WAIT=1 ;;
        --allow-unsafe-switch) ALLOW_UNSAFE_SWITCH=1 ;;
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

for tool in nix jq git ssh curl colmena timeout; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "error: required tool not on PATH: $tool" >&2
        exit 1
    }
done

cd "$(git rev-parse --show-toplevel)"

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

# Both maps come out of ONE evaluation. Evaluating the hive is the expensive
# part of this script -- it is a full module-system evaluation per node -- and
# asking for systemd.package separately would very nearly double the run time
# for one extra store path. EXPECTED_JSON is then split back out unchanged, so
# everything downstream (the probe loop, the manifest guard's jq) still sees the
# flat {node: toplevel} shape it was written against.
echo "Evaluating what colmena would deploy..." >&2
if ! COMBINED_JSON="$(
    nix eval --json '.#colmenaHive.nodes' \
        --apply 'ns: {
          toplevel = builtins.mapAttrs (_: n: n.config.system.build.toplevel.outPath) ns;
          systemd = builtins.mapAttrs (_: n: n.config.systemd.package.outPath) ns;
        }' \
        2>"$EVAL_STDERR"
)"; then
    printf 'error: failed to evaluate colmenaHive nodes:\n%s\n' "$(cat "$EVAL_STDERR")" >&2
    exit 1
fi
EXPECTED_JSON="$(jq -c '.toplevel' <<<"$COMBINED_JSON")"
SYSTEMD_JSON="$(jq -c '.systemd' <<<"$COMBINED_JSON")"

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

# --- Determine what each node is actually running -------------------------
#
# Done BEFORE the manifest guard, so the guard can be scoped to the nodes that
# are actually going to be deployed. Checking every evaluated node instead would
# refuse the whole run because some node that needs no deploy happens to have an
# unpublished closure -- blocking a safe deployment for an unrelated host.

DRIFTED=()
CURRENT=()
UNREACHABLE=()
FREEZE_RISK=()
FREEZE_UNKNOWN=()

for node in "${NODES[@]}"; do
    expected="$(jq -r --arg n "$node" '.[$n]' <<<"$EXPECTED_JSON")"
    host="$(jq -r --arg n "$node" '.[$n].targetHost // ""' <<<"$DEPLOY_JSON")"
    port="$(jq -r --arg n "$node" '.[$n].targetPort // 22' <<<"$DEPLOY_JSON")"
    user="$(jq -r --arg n "$node" '.[$n].targetUser // "root"' <<<"$DEPLOY_JSON")"

    if [[ -z "$host" ]]; then
        UNREACHABLE+=("$node (no targetHost)")
        continue
    fi

    # StrictHostKeyChecking is pinned to yes rather than left to the caller's
    # ssh_config, and certainly not set to accept-new.
    #
    # This probe decides whether a host is skipped. An attacker able to spoof DNS
    # or a route could present their own host key, answer with the expected
    # closure path, and cause a genuinely drifted host to be classified as
    # current -- silently withholding a deploy, which is the one failure
    # direction here that matters. Trust-on-first-use is therefore the wrong
    # default, and relying on the ambient config is not enough either: a
    # `StrictHostKeyChecking no` entry in ~/.ssh/config would silently defeat it.
    #
    # Every node is already in known_hosts because colmena connects to them, so
    # an unknown key means something is wrong. It fails, lands the node in
    # UNREACHABLE, and gets reported rather than skipped.
    #
    # The outer timeout bounds the whole session, which ConnectTimeout does not:
    # it only covers reaching the port. A host that accepts the connection and
    # then wedges -- full disk, load spike, D-state -- would otherwise block the
    # loop forever and prevent every later node from being classified.
    # Retried once. A transient blip -- flaky mDNS for a .local name, a moment of
    # packet loss -- otherwise demotes a host to UNREACHABLE, and the run then
    # proceeds without it. That is the one failure direction that matters here:
    # withholding a deploy from a host that needed one. Observed in practice, so
    # this is not hypothetical.
    # The probe also collects the two preconditions of the PID 1 freeze
    # (nixpkgs#375376) while the connection is open, rather than opening a
    # second round of SSH sessions later: the systemd build the node is running
    # (a change means the deploy will daemon-reexec) and whether it has live
    # network filesystems (whose stat() is what hangs the generators). Emitted
    # as key=value lines so adding a field later cannot silently shift the
    # meaning of an existing one, the way positional lines would.
    probe_out=""
    probe_ok=0
    for attempt in 1 2; do
        # shellcheck disable=SC2016
        # The single quotes are the point: every $ in this block must expand on
        # the REMOTE host. Double quotes would expand them locally and ship a
        # pre-evaluated snapshot of this machine's state instead.
        if probe_out="$(
            timeout 30 ssh \
                -o BatchMode=yes \
                -o ConnectTimeout=10 \
                -o StrictHostKeyChecking=yes \
                -p "$port" "${user}@${host}" '
                  printf "toplevel=%s\n" "$(readlink -f /run/current-system)"
                  printf "systemd=%s\n" "$(readlink -f /run/current-system/systemd 2>/dev/null)"
                  printf "netfs=%s\n" "$(findmnt -t nfs,nfs4,cifs -n -o TARGET 2>/dev/null | wc -l)"
                ' 2>/dev/null
        )"; then
            probe_ok=1
            break
        fi
        [[ "$attempt" -eq 1 ]] && sleep 3
    done

    if [[ "$probe_ok" -eq 0 ]]; then
        UNREACHABLE+=("$node ($host)")
        continue
    fi

    running="$(sed -n 's/^toplevel=//p' <<<"$probe_out" | head -1)"
    running_systemd="$(sed -n 's/^systemd=//p' <<<"$probe_out" | head -1)"
    running_netfs="$(sed -n 's/^netfs=//p' <<<"$probe_out" | head -1)"

    # An empty toplevel means the remote command ran but produced nothing
    # usable. Treating that as drift would deploy on the strength of a failed
    # probe; treating it as current would silently skip the node forever.
    if [[ -z "$running" ]]; then
        UNREACHABLE+=("$node ($host: probe returned no toplevel)")
        continue
    fi

    if [[ "$running" == "$expected" ]]; then
        CURRENT+=("$node")
        continue
    fi

    DRIFTED+=("$node")

    # Danger = the deploy re-execs PID 1 AND there is something for the
    # generators to hang on. Both must hold; either alone is routine.
    #
    # A field we could not read is NOT the same as a field that says "no". If
    # the probe came back partial, falling through to the risk test would
    # evaluate it as safe and silently disable the guard for that node -- the
    # one direction that matters here, since the cost of a false negative is a
    # frozen box that needs physically visiting. Unknowns are split out and
    # reported instead of being folded into either answer.
    target_systemd="$(jq -r --arg n "$node" '.[$n] // ""' <<<"$SYSTEMD_JSON")"
    if [[ -z "$running_systemd" || -z "$target_systemd" || ! "$running_netfs" =~ ^[0-9]+$ ]]; then
        FREEZE_UNKNOWN+=("$node ($host): incomplete probe (systemd='${running_systemd:-?}' netfs='${running_netfs:-?}')")
    elif [[ "$running_systemd" != "$target_systemd" && "$running_netfs" -gt 0 ]]; then
        FREEZE_RISK+=("$node ($host): systemd changes and $running_netfs network mount(s) live")
    fi
done

printf '\n%-12s %s\n' "current:" "${CURRENT[*]:-none}"
printf '%-12s %s\n' "to deploy:" "${DRIFTED[*]:-none}"
if [[ ${#UNREACHABLE[@]} -gt 0 ]]; then
    # Reported rather than silently skipped: an unreachable node is one colmena
    # could not have deployed either, and treating it as "current" would quietly
    # leave it behind forever.
    printf '%-12s %s\n' "unreachable:" "${UNREACHABLE[*]}"
fi
echo

if [[ ${#DRIFTED[@]} -eq 0 ]]; then
    echo "Nothing to deploy."
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

TARGETS="$(
    IFS=,
    echo "${DRIFTED[*]}"
)"

# --- PID 1 freeze guard ---------------------------------------------------
#
# A `switch` that re-execs PID 1 while the node has network filesystems mounted
# can leave systemd frozen: alive but deaf to D-Bus, so nothing starts or stops
# and `reboot` -- itself a D-Bus call to PID 1 -- hangs too (nixpkgs#375376).
#
# Locally that costs a walk to the power button. On a remote node it costs a
# trip to wherever the box lives, so the default here is to refuse rather than
# to warn. Deploying with `--goal boot` and rebooting reaches the same
# generation without ever re-execing PID 1 on the running system.
#
# Skipped when the caller already chose a goal: passing `-- --goal boot` is the
# recommended remedy, and `-- --goal build`/`push`/`dry-activate` do not
# activate anything, so none of them can trip this.
caller_set_goal=0
for arg in ${COLMENA_ARGS[@]+"${COLMENA_ARGS[@]}"}; do
    [[ "$arg" == "--goal" || "$arg" == --goal=* ]] && caller_set_goal=1
done

if [[ ${#FREEZE_RISK[@]} -gt 0 && $ALLOW_UNSAFE_SWITCH -eq 0 && $caller_set_goal -eq 0 ]]; then
    {
        echo "error: refusing to switch nodes that could freeze PID 1."
        echo
        for entry in "${FREEZE_RISK[@]}"; do
            echo "  $entry"
        done
        cat <<EOF

  These nodes would daemon-reexec systemd during activation while network
  filesystems are mounted. If the fileserver is unreachable at that moment the
  fstab generator blocks, PID 1 times out after 90s and freezes, and the node
  stops responding to both systemctl and reboot. See NixOS/nixpkgs#375376.

  Stage the closure and reboot into it instead -- same generation, no re-exec
  of a running PID 1:

    scripts/colmena-apply-drifted.sh -- --goal boot
    # then reboot those nodes

  To deploy anyway, knowing the node may need physical access:

    scripts/colmena-apply-drifted.sh --allow-unsafe-switch
EOF
    } >&2
    exit 1
fi

if [[ ${#FREEZE_RISK[@]} -gt 0 ]]; then
    {
        echo "warning: proceeding despite PID 1 freeze risk on:"
        for entry in "${FREEZE_RISK[@]}"; do
            echo "  $entry"
        done
        echo
    } >&2
fi

if [[ ${#FREEZE_UNKNOWN[@]} -gt 0 ]]; then
    {
        echo "warning: the PID 1 freeze guard could not evaluate these nodes:"
        for entry in "${FREEZE_UNKNOWN[@]}"; do
            echo "  $entry"
        done
        echo "  They are NOT known to be safe -- the guard simply has no answer"
        echo "  for them. Deploying with --goal boot avoids the question entirely."
        echo
    } >&2
fi

if [[ $DRY_RUN -eq 1 ]]; then
    echo "would run: colmena apply --on $TARGETS ${COLMENA_ARGS[*]}"
    exit 0
fi

echo "Running: colmena apply --on $TARGETS ${COLMENA_ARGS[*]}"

# Not `exec`: the deferred-restart report below has to run after colmena
# finishes. Colmena's exit code is captured and re-raised so callers and CI see
# exactly what they saw before.
set +e
colmena apply --on "$TARGETS" ${COLMENA_ARGS[@]+"${COLMENA_ARGS[@]}"}
COLMENA_RC=$?
set -e

# --- Deferred restarts on the deployed nodes ------------------------------
#
# NetworkManager is reloaded rather than restarted on activation
# (features/common/system/default.nix), which is what keeps the network up
# across a daemon-reexec. The cost is that the running daemon is still the old
# binary afterwards, so a NetworkManager update -- including a security fix --
# is not live until something restarts it or the node reboots.
#
# Detected the same way switch-preflight.sh does it locally: ask whether the
# binary the process actually has open is still in /run/current-system's
# closure. Comparing ExecStart against /proc/exe instead would false-positive on
# every unit whose ExecStart is a generated unit-script-*-start wrapper.
if [[ $COLMENA_RC -eq 0 ]]; then
    deferred_report=""
    for node in "${DRIFTED[@]}"; do
        host="$(jq -r --arg n "$node" '.[$n].targetHost // ""' <<<"$DEPLOY_JSON")"
        port="$(jq -r --arg n "$node" '.[$n].targetPort // 22' <<<"$DEPLOY_JSON")"
        user="$(jq -r --arg n "$node" '.[$n].targetUser // "root"' <<<"$DEPLOY_JSON")"
        [[ -n "$host" ]] || continue

        # shellcheck disable=SC2016
        # Single-quoted deliberately: these expansions belong to the remote
        # shell. Expanding them here would compare the remote units against
        # THIS machine's closure, which is meaningless.
        stale="$(
            timeout 30 ssh \
                -o BatchMode=yes \
                -o ConnectTimeout=10 \
                -o StrictHostKeyChecking=yes \
                -p "$port" "${user}@${host}" '
                  req=$(nix-store -q --requisites /run/current-system 2>/dev/null) || exit 0
                  for unit in NetworkManager.service wpa_supplicant.service \
                              systemd-networkd.service dhcpcd.service; do
                    [ "$(systemctl show -p ActiveState --value "$unit" 2>/dev/null)" = active ] || continue
                    pid=$(systemctl show -p MainPID --value "$unit" 2>/dev/null)
                    [ -n "$pid" ] && [ "$pid" != 0 ] || continue
                    exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null) || continue
                    sp=$(printf "%s" "$exe" | grep -oE "/nix/store/[a-z0-9]{32}-[^/]+" | head -1)
                    [ -n "$sp" ] || continue
                    printf "%s\n" "$req" | grep -qxF "$sp" || printf "%s (%s)\n" "$unit" "$sp"
                  done
                ' 2>/dev/null || true
        )"

        [[ -n "$stale" ]] || continue
        deferred_report+="  ${node}:"$'\n'
        while IFS= read -r line; do
            [[ -n "$line" ]] && deferred_report+="    ${line}"$'\n'
        done <<<"$stale"
    done

    if [[ -n "$deferred_report" ]]; then
        cat >&2 <<EOF

NOTE: these nodes have network units that changed but were reloaded rather
than restarted, so they are still running the previous binary:

${deferred_report}
  Activation deliberately does not restart them -- that is what keeps the
  network up across a systemd re-exec. But the update is NOT live yet; if it
  was a security fix those nodes are not patched.

  Clear it per node with a brief network blip:
    ssh <node> systemctl restart NetworkManager
  or on the next reboot.
EOF
    fi
fi

exit "$COLMENA_RC"
