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
# Two independent hazards below (PID 1 freeze, critical-unit restart) make a
# live `switch` unsafe for SOME nodes in a run, not all of them. A single
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
# THE PID 1 FREEZE HAZARD
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
# Nodes with both are held back rather than warned about, because recovering a
# frozen remote node means physically visiting it.
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
# REBOOT MODE
#
# `--reboot` is the other half of the `boot` goal: it finds every node whose
# system profile points somewhere other than /run/current-system -- the exact
# signature of a staged-but-not-activated generation -- and reboots them one at
# a time, waiting for each to come back on the new closure before touching the
# next. Nodes with critical units go first, so the cache and DNS are settled
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
#   scripts/colmena-apply-drifted.sh --allow-unsafe-switch     # ignore the freeze hazard
#   scripts/colmena-apply-drifted.sh --allow-critical-restart  # ignore the critical-unit hazard
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
ALLOW_CRITICAL_RESTART=0
REBOOT_MODE=0
ASSUME_YES=0
COLMENA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --force) FORCE=1 ;;
        --wait) WAIT=1 ;;
        --allow-unsafe-switch) ALLOW_UNSAFE_SWITCH=1 ;;
        --allow-critical-restart) ALLOW_CRITICAL_RESTART=1 ;;
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
    [[ $ALLOW_CRITICAL_RESTART -eq 1 ]] && reboot_conflict="--allow-critical-restart"
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

# All three maps come out of ONE evaluation. Evaluating the hive is the
# expensive part of this script -- it is a full module-system evaluation per
# node -- and asking for systemd.package or the critical units separately would
# multiply the run time for a handful of extra store paths. The result is then
# split back out unchanged, so everything downstream (the probe loop, the
# manifest guard's jq) still sees the flat {node: toplevel} shape it was written
# against.
#
# `critical` is keyed by node, then by unit name, and carries both the reason
# the unit is protected and the unit-file store path the target closure would
# install. Indexing systemd.units.<unit> directly is safe because
# modules/base/deployment-meta.nix asserts every declared unit exists -- a typo
# fails evaluation there rather than silently producing an empty map here, which
# would read as "nothing critical changed".
echo "Evaluating what colmena would deploy..." >&2
# shellcheck disable=SC2016
# Single-quoted on purpose: this is a Nix expression, and `${unit}` below is
# Nix string interpolation. Letting the shell touch it would substitute an
# empty local variable and evaluate `systemd.units.""`.
if ! COMBINED_JSON="$(
    nix eval --json '.#colmenaHive.nodes' \
        --apply 'ns: {
          toplevel = builtins.mapAttrs (_: n: n.config.system.build.toplevel.outPath) ns;
          systemd = builtins.mapAttrs (_: n: n.config.systemd.package.outPath) ns;
          critical = builtins.mapAttrs (
            _: n:
              builtins.mapAttrs (unit: reason: {
                inherit reason;
                path = n.config.systemd.units.${unit}.unit.outPath;
              }) n.config.deployment.criticalUnits
          ) ns;
        }' \
        2>"$EVAL_STDERR"
)"; then
    printf 'error: failed to evaluate colmenaHive nodes:\n%s\n' "$(cat "$EVAL_STDERR")" >&2
    exit 1
fi
EXPECTED_JSON="$(jq -c '.toplevel' <<<"$COMBINED_JSON")"
SYSTEMD_JSON="$(jq -c '.systemd' <<<"$COMBINED_JSON")"
CRITICAL_JSON="$(jq -c '.critical' <<<"$COMBINED_JSON")"

# Unit names are interpolated into the remote probe script, so they are checked
# here rather than trusted. The set allowed is what systemd itself permits in a
# unit name; anything else is a mistake or an injection attempt, and neither
# should reach an `ssh` command line.
if ! bad_units="$(
    jq -r '[ .[] | keys[] ] | unique
           | map(select(test("^[A-Za-z0-9@:._\\\\-]+\\.[a-z]+$") | not))
           | join(" ")' <<<"$CRITICAL_JSON"
)"; then
    echo "error: could not validate deployment.criticalUnits names" >&2
    exit 1
fi
if [[ -n "$bad_units" ]]; then
    echo "error: deployment.criticalUnits contains unusable unit name(s): $bad_units" >&2
    exit 1
fi

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
# One SSH session per node collects everything any later stage needs, rather
# than each guard opening its own round of connections: what the node is
# running, the two preconditions of the PID 1 freeze (nixpkgs#375376), the
# unit-file store path of each of its critical units, and whether it already
# has a staged generation waiting for a reboot.
#
# Emitted as key=value lines so adding a field later cannot silently shift the
# meaning of an existing one, the way positional lines would. `unit:<name>=` is
# namespaced for the same reason -- a unit called `netfs` cannot collide with
# the netfs field.
#
# A field that could not be READ is deliberately distinguishable from a field
# that says "no": every guard downstream treats "?" as unknown and reports it,
# because a failed probe silently evaluating as "safe" is the one failure
# direction that matters here.
#
# shellcheck disable=SC2016
# The single quotes are the point: every $ in this block must expand on the
# REMOTE host. Double quotes would expand them locally and ship a pre-evaluated
# snapshot of this machine's state instead. CRITICAL_UNITS is supplied by
# probe_node as a separate assignment prepended to this body.
PROBE_BODY='
  printf "toplevel=%s\n" "$(readlink -f /run/current-system)"
  printf "systemd=%s\n" "$(readlink -f /run/current-system/systemd 2>/dev/null)"

  # The system profile is what `boot` updates and `switch` also updates: it
  # points at the generation the bootloader will start. Differing from
  # /run/current-system is therefore the exact signature of a staged-but-not-
  # activated closure, which is what --reboot looks for. Derived from the
  # profile rather than by parsing bootloader entries, which differ per
  # bootloader and per generation-limit setting.
  printf "profile=%s\n" "$(readlink -f /nix/var/nix/profiles/system 2>/dev/null)"

  # findmnt exits 1 for "no matches" and >1 for real errors (including not
  # being installed). Piping straight into `wc -l` discards that distinction
  # and reports 0 for both, which would tell the guard there are no network
  # mounts on a node we simply failed to inspect -- a false negative in the
  # one direction that matters. Emit "?" for a genuine failure so the caller
  # records it as UNKNOWN instead.
  netfs_out=$(findmnt -t nfs,nfs4,cifs -n -o TARGET 2>/dev/null)
  netfs_rc=$?
  if [ "$netfs_rc" -eq 0 ]; then
    printf "netfs=%s\n" "$(printf "%s\n" "$netfs_out" | grep -c .)"
  elif [ "$netfs_rc" -eq 1 ]; then
    printf "netfs=0\n"
  else
    printf "netfs=?\n"
  fi

  # The unit DERIVATION path, not the file inside it: /etc/systemd/system/<u>
  # resolves to /nix/store/<hash>-unit-<u>/<u>, and the caller compares against
  # config.systemd.units.<u>.unit, which is the directory. Stripping the last
  # component makes the two directly comparable.
  #
  # "absent" is not "?": a critical unit the running generation does not have
  # yet will be STARTED by activation, not restarted, so there is no running
  # process to disrupt and no reason to hold the node back.
  for u in $CRITICAL_UNITS; do
    f="/run/current-system/etc/systemd/system/$u"
    if [ -L "$f" ] || [ -e "$f" ]; then
      p=$(readlink -f "$f" 2>/dev/null)
      if [ -n "$p" ]; then
        printf "unit:%s=%s\n" "$u" "${p%/*}"
      else
        printf "unit:%s=?\n" "$u"
      fi
    else
      printf "unit:%s=absent\n" "$u"
    fi
  done
'

# Probe one node. Prints the key=value block on stdout; returns non-zero if the
# node could not be reached at all.
#
#   $1 host   $2 port   $3 user   $4 space-separated critical unit names
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
    local host="$1" port="$2" user="$3" units="$4" attempts="${5:-2}"
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
                2>/dev/null <<<"CRITICAL_UNITS='${units}'
${PROBE_BODY}"
        )"; then
            printf '%s\n' "$out"
            return 0
        fi
        [[ "$attempt" -lt "$attempts" ]] && sleep 3
    done
    return 1
}

# Read one key=value field out of a probe block. Named rather than inlined
# because every field is read the same way and `unit:` keys contain a `.`,
# which makes an ad-hoc sed expression easy to get subtly wrong.
probe_field() {
    local block="$1" key="$2"
    awk -v k="$key" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' <<<"$block"
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
FREEZE_RISK=()
FREEZE_UNKNOWN=()
CRITICAL_HOLD=()
CRITICAL_UNKNOWN=()
STAGED=()

# The *_NODES arrays carry bare node names for the bucketing below, while the
# arrays above carry the human-readable explanation. Kept separate rather than
# parsing the node name back out of a message: the message format is for
# people and is expected to change, and re-parsing it would turn a wording
# tweak into a silent mis-bucketing.
FREEZE_RISK_NODES=()
CRITICAL_HOLD_NODES=()

# Parallel arrays indexed alongside NODES, so later stages (the reboot flow in
# particular) do not need a second round of SSH or jq to recover what the probe
# already learned. Bash 4 associative arrays would read better, but this script
# already avoids them elsewhere for portability.
PROBE_NODES=()
PROBE_RUNNING=()
PROBE_PROFILE=()

for node in "${NODES[@]}"; do
    expected="$(jq -r --arg n "$node" '.[$n]' <<<"$EXPECTED_JSON")"
    host="$(jq -r --arg n "$node" '.[$n].targetHost // ""' <<<"$DEPLOY_JSON")"
    port="$(jq -r --arg n "$node" '.[$n].targetPort // 22' <<<"$DEPLOY_JSON")"
    user="$(jq -r --arg n "$node" '.[$n].targetUser // "root"' <<<"$DEPLOY_JSON")"
    units="$(node_critical_units "$node")"

    if [[ -z "$host" ]]; then
        UNREACHABLE+=("$node (no targetHost)")
        continue
    fi

    if ! probe_out="$(probe_node "$host" "$port" "$user" "$units")"; then
        UNREACHABLE+=("$node ($host)")
        continue
    fi

    running="$(probe_field "$probe_out" toplevel)"
    running_systemd="$(probe_field "$probe_out" systemd)"
    running_netfs="$(probe_field "$probe_out" netfs)"
    running_profile="$(probe_field "$probe_out" profile)"

    # An empty toplevel means the remote command ran but produced nothing
    # usable. Treating that as drift would deploy on the strength of a failed
    # probe; treating it as current would silently skip the node forever.
    if [[ -z "$running" ]]; then
        UNREACHABLE+=("$node ($host: probe returned no toplevel)")
        continue
    fi

    PROBE_NODES+=("$node")
    PROBE_RUNNING+=("$running")
    PROBE_PROFILE+=("$running_profile")

    # A generation the bootloader will start but that is not running: either an
    # earlier `boot`-goal deploy that has not been rebooted into, or a local
    # `nixos-rebuild boot` on the node. Recorded regardless of drift, because a
    # node whose staged closure IS the expected one looks perfectly current to
    # the profile comparison while still owing a reboot.
    if [[ -n "$running_profile" && "$running_profile" != "$running" ]]; then
        STAGED+=("$node")
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
        FREEZE_RISK_NODES+=("$node")
    fi

    # Critical units: would activation restart one?
    #
    # switch-to-configuration restarts a unit exactly when its unit file
    # changed, so comparing the unit derivation the node is running against the
    # one the target closure installs is a decision, not an estimate.
    #
    # Same unknown-is-not-no rule as above. "absent" IS an answer: the unit does
    # not exist in the running generation, so activation starts it rather than
    # restarting it, and there is nothing running to disrupt.
    for unit in $units; do
        have="$(probe_field "$probe_out" "unit:${unit}")"
        want="$(jq -r --arg n "$node" --arg u "$unit" '.[$n][$u].path // ""' <<<"$CRITICAL_JSON")"
        reason="$(jq -r --arg n "$node" --arg u "$unit" '.[$n][$u].reason // "no reason recorded"' <<<"$CRITICAL_JSON")"

        if [[ -z "$have" || "$have" == "?" || -z "$want" ]]; then
            CRITICAL_UNKNOWN+=("$node ($host): could not compare $unit (running='${have:-?}')")
        elif [[ "$have" == "absent" ]]; then
            continue
        elif [[ "$have" != "$want" ]]; then
            CRITICAL_HOLD+=("$node ($host): $unit would restart -- $reason")
            CRITICAL_HOLD_NODES+=("$node")
        fi
    done
done

printf '\n%-12s %s\n' "current:" "${CURRENT[*]:-none}"
printf '%-12s %s\n' "to deploy:" "${DRIFTED[*]:-none}"
if [[ ${#STAGED[@]} -gt 0 ]]; then
    # Not a warning: this is the normal state between a held-back deploy and the
    # reboot that applies it. Reported because the alternative is a node sitting
    # on an unactivated generation indefinitely with nothing saying so.
    printf '%-12s %s\n' "staged:" "${STAGED[*]} (awaiting reboot)"
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
        units="$(node_critical_units "$node")"
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
            if out="$(probe_node "$host" "$port" "$user" "$units" 1)"; then
                now="$(probe_field "$out" toplevel)"
                # The node must be up AND running the closure it was staged
                # with. Reachability alone is not enough: sshd answers well
                # before the check is meaningful, and if the node came back on
                # the OLD generation the reboot did not do what was asked.
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
# so neither hazard can fire and every node goes in one bucket.
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

STAGE_BUCKET=()
SWITCH_BUCKET=()
for node in "${DRIFTED[@]}"; do
    hold=0
    if [[ $goal_activates -eq 1 ]]; then
        if [[ $ALLOW_UNSAFE_SWITCH -eq 0 ]] &&
            contains "$node" ${FREEZE_RISK_NODES[@]+"${FREEZE_RISK_NODES[@]}"}; then
            hold=1
        fi
        if [[ $ALLOW_CRITICAL_RESTART -eq 0 ]] &&
            contains "$node" ${CRITICAL_HOLD_NODES[@]+"${CRITICAL_HOLD_NODES[@]}"}; then
            hold=1
        fi
    fi
    if [[ $hold -eq 1 ]]; then
        STAGE_BUCKET+=("$node")
    else
        SWITCH_BUCKET+=("$node")
    fi
done

# `test` cannot be auto-split (see above), so a held node under `test` is a
# refusal, not a staging.
if [[ "$colmena_goal" == "test" && ${#STAGE_BUCKET[@]} -gt 0 ]]; then
    {
        echo "error: refusing to \`test\` nodes that are held back: ${STAGE_BUCKET[*]}"
        echo
        # Filtered to the held nodes: an override may already have cleared a
        # hazard for some other node, and listing it here as a reason for this
        # refusal would send the reader after the wrong flag.
        for entry in ${FREEZE_RISK[@]+"${FREEZE_RISK[@]}"} ${CRITICAL_HOLD[@]+"${CRITICAL_HOLD[@]}"}; do
            contains "${entry%% *}" "${STAGE_BUCKET[@]}" && echo "  $entry"
        done
        cat <<EOF

  \`test\` activates without touching the bootloader, so this script will not
  silently substitute the \`boot\` goal for it the way it does for \`switch\`.

  Either drop the explicit goal and let the default split handle it:

    scripts/colmena-apply-drifted.sh

  or override the specific hazard you have judged acceptable:

    scripts/colmena-apply-drifted.sh --allow-unsafe-switch -- test
    scripts/colmena-apply-drifted.sh --allow-critical-restart -- test
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
        for entry in ${FREEZE_RISK[@]+"${FREEZE_RISK[@]}"}; do
            contains "${entry%% *}" "${STAGE_BUCKET[@]}" && echo "  $entry"
        done
        for entry in ${CRITICAL_HOLD[@]+"${CRITICAL_HOLD[@]}"}; do
            contains "${entry%% *}" "${STAGE_BUCKET[@]}" && echo "  $entry"
        done
        echo
    } >&2
fi

# Overridden hazards are still reported. The override says "I accept this", not
# "do not tell me".
if [[ $ALLOW_UNSAFE_SWITCH -eq 1 && ${#FREEZE_RISK[@]} -gt 0 && $goal_activates -eq 1 ]]; then
    {
        echo "warning: proceeding despite PID 1 freeze risk on (--allow-unsafe-switch):"
        for entry in "${FREEZE_RISK[@]}"; do
            echo "  $entry"
        done
        echo "  A node that freezes this way stops answering both systemctl AND reboot,"
        echo "  and needs physical access. See NixOS/nixpkgs#375376."
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

if [[ ${#FREEZE_UNKNOWN[@]} -gt 0 ]]; then
    {
        echo "warning: the PID 1 freeze guard could not evaluate these nodes:"
        for entry in "${FREEZE_UNKNOWN[@]}"; do
            echo "  $entry"
        done
        echo "  They are NOT known to be safe -- the guard simply has no answer"
        echo "  for them. Deploying with the \`boot\` goal avoids the question entirely."
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
#
# Scoped to the nodes that were actually activated. A staged node's
# /run/current-system is untouched by definition, so every unit on it is
# trivially consistent with it and the scan can only produce noise -- noise
# that would read as an all-clear for a node whose update is not applied at all.
if [[ $COLMENA_RC -eq 0 && ${#SWITCH_BUCKET[@]} -gt 0 && $goal_activates -eq 1 ]]; then
    deferred_report=""
    for node in "${SWITCH_BUCKET[@]}"; do
        host="$(jq -r --arg n "$node" '.[$n].targetHost // ""' <<<"$DEPLOY_JSON")"
        port="$(jq -r --arg n "$node" '.[$n].targetPort // 22' <<<"$DEPLOY_JSON")"
        user="$(jq -r --arg n "$node" '.[$n].targetUser // "root"' <<<"$DEPLOY_JSON")"
        [[ -n "$host" ]] || continue

        # shellcheck disable=SC2016
        # Single-quoted deliberately: these expansions belong to the remote
        # shell. Expanding them here would compare the remote units against
        # THIS machine's closure, which is meaningless.
        #
        # `/bin/sh -s` for the same reason as probe_node: the account's login
        # shell is zsh, whose word-splitting rules differ from POSIX sh. This
        # block happens not to depend on them, but pinning the interpreter
        # costs nothing and keeps the next edit from having to know that.
        stale="$(
            timeout 30 ssh \
                -o BatchMode=yes \
                -o ConnectTimeout=10 \
                -o StrictHostKeyChecking=yes \
                -p "$port" "${user}@${host}" /bin/sh -s 2>/dev/null <<<'
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
' || true
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
