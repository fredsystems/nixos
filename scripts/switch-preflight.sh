#!/usr/bin/env bash
#
# switch-preflight.sh -- decide whether `nixos-rebuild switch` is safe to run
# live on THIS machine, or whether the new generation must be reached with
# `boot` + reboot instead.
#
# This is the local half of the fleet's one deploy policy. Every rule lives in
# scripts/lib/deploy-guard.sh, which scripts/colmena-apply-drifted.sh sources
# for the servers; the target side is flake/lib/deploy-facts.nix, which both
# evaluate. This script only gathers the facts for the local machine and turns
# the verdict into an exit code for `updatenix` (dotfiles/shell/40-functions.sh).
#
# WHAT HOLDS A LIVE SWITCH
#
#   systemd    systemd's store path moves, so `switch` would re-exec PID 1.
#              A re-exec whose fstab generator stalls on an NFS mount freezes
#              PID 1 so hard that `reboot` hangs too (NixOS/nixpkgs#375376,
#              observed on maranello 2026-08-29 and repeatedly on Daytona).
#              This used to also require a live NFS mount and a network unit
#              going down, but `findmnt -t nfs` cannot see an idle
#              x-systemd.automount share -- and that is how every NAS mount
#              here is declared (modules/services/nas-system.nix) -- so it
#              waved through exactly the case it existed to stop.
#   kernel     the kernel or its module set differs from what was BOOTED.
#              `switch` cannot load it; the reboot is owed either way.
#   critical   a deployment.criticalUnits unit would be restarted.
#   process    a deployment.criticalProcesses package -- the compositor you
#              are logged into -- would move to a different VERSION. Config
#              changes and same-version rebuilds are not held; compositors
#              that are installed but not running are not held.
#   display manager
#              the program display-manager.service is running (sddm, greetd,
#              whatever it is) is not the one the target runs. `switch` keeps
#              the old one running but deletes its user, PAM services and
#              config, so the next logout shows no login screen (Daytona,
#              2026-10-27, sddm -> greetd). Overridden by
#              --allow-process-change. An earlier switch that already crossed
#              such a change is reported as a reboot owed.
#
# Anything that cannot be read is held, not waved through. Wrongly holding
# costs a reboot; wrongly switching can cost a frozen machine.
#
# Nothing is built or activated: the target is EVALUATED (seconds), and the
# running system is read through /run and /proc. `nixos-rebuild` does the
# build afterwards.
#
# AFTER THE SWITCH: --deferred
#
# Lists every process still running a binary from before the switch: system
# daemons activation reloaded instead of restarting (NetworkManager, by
# design -- features/common/system/default.nix), and the apps open in your
# session that are now behind the installed version. Nothing is held for
# these; it is the list of what to restart when convenient.
#
# Usage:
#   sudo scripts/switch-preflight.sh                        # verdict for .#<hostname>
#   sudo scripts/switch-preflight.sh --flake ~/nixos#maranello
#   sudo scripts/switch-preflight.sh --deferred             # after a switch
#   scripts/switch-preflight.sh --facts-file F --probe-file P   # classify captured data
#   scripts/switch-preflight.sh --quiet                     # verdict only
#   ... --allow-unsafe-switch      # switch despite a systemd change
#   ... --allow-kernel-switch      # switch despite a kernel change
#   ... --allow-critical-restart   # switch despite a critical-unit restart
#   ... --allow-process-change     # switch despite a critical-process or display-manager change
#
# --facts-file takes one node's object from `.#lib.deployFacts.nixos.<host>`;
# --probe-file takes the output of the probe (DG_PROBE_BODY). Together they
# classify without root and without touching the running system, which is
# what the test suite uses.
#
# Exit codes:
#   0   safe to `switch` (or: nothing to do -- already running the target)
#   10  do NOT switch live -- use `nixos-rebuild boot` and reboot
#   1   error: the verdict is unknown, so do neither blindly

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/deploy-guard.sh
source "$SCRIPT_DIR/lib/deploy-guard.sh"

FLAKE_REF=""
FACTS_FILE=""
PROBE_FILE=""
DEFERRED_ONLY=0
QUIET=0
ALLOW_UNSAFE_SWITCH=0
ALLOW_KERNEL_SWITCH=0
ALLOW_CRITICAL_RESTART=0
ALLOW_PROCESS_CHANGE=0

need_value() {
    [[ $2 -ge 2 ]] || {
        echo "error: $1 needs a value" >&2
        exit 1
    }
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --flake)
            need_value "$1" "$#"
            FLAKE_REF="$2"
            shift
            ;;
        --facts-file)
            need_value "$1" "$#"
            FACTS_FILE="$2"
            shift
            ;;
        --probe-file)
            need_value "$1" "$#"
            PROBE_FILE="$2"
            shift
            ;;
        --deferred) DEFERRED_ONLY=1 ;;
        --quiet) QUIET=1 ;;
        --allow-unsafe-switch) ALLOW_UNSAFE_SWITCH=1 ;;
        --allow-kernel-switch) ALLOW_KERNEL_SWITCH=1 ;;
        --allow-critical-restart) ALLOW_CRITICAL_RESTART=1 ;;
        --allow-process-change) ALLOW_PROCESS_CHANGE=1 ;;
        -h | --help)
            # Print the header block by structure, not by line number, so it
            # cannot silently truncate as the header grows.
            awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            exit 1
            ;;
    esac
    shift
done

say() {
    [[ "$QUIET" -eq 1 ]] || printf '%s\n' "$*"
}

# ---------------------------------------------------------------------------
# --deferred: what is still running from before the switch
# ---------------------------------------------------------------------------
if [[ "$DEFERRED_ONLY" -eq 1 ]]; then
    scan_file="$(mktemp)"
    trap 'rm -f "$scan_file"' EXIT
    # Straight to a file; see dg_scan_report for why it is never a variable.
    dg_scan_script | /bin/sh -s >"$scan_file" 2>/dev/null || true
    if [[ "$(id -u)" -ne 0 ]]; then
        say "note: not root, so other users' processes (every system daemon) cannot be read."
    fi
    # Informational: the switch already happened, so there is no verdict to
    # return. dg_scan_report says itself when the answer is incomplete.
    dg_scan_report "$scan_file" || true
    exit 0
fi

# ---------------------------------------------------------------------------
# Facts: the target (evaluated) and the running system (probed)
# ---------------------------------------------------------------------------
fixture_mode=0
if [[ -n "$FACTS_FILE" || -n "$PROBE_FILE" ]]; then
    if [[ -z "$FACTS_FILE" || -z "$PROBE_FILE" ]]; then
        echo "error: --facts-file and --probe-file go together" >&2
        exit 1
    fi
    fixture_mode=1
fi

# Reading /proc/<pid>/exe for other users' processes -- and for a
# non-dumpable compositor even of your own -- needs root. Without it the
# process rule cannot rule out a running compositor and holds, which is the
# correct answer to an unreadable system but a useless one.
if [[ "$fixture_mode" -eq 0 && "$(id -u)" -ne 0 ]]; then
    echo "error: preflight must run as root (it reads /proc of every process; it changes nothing)" >&2
    echo "  try: sudo $0${FLAKE_REF:+ --flake $FLAKE_REF}" >&2
    exit 1
fi

if [[ "$fixture_mode" -eq 1 ]]; then
    for f in "$FACTS_FILE" "$PROBE_FILE"; do
        [[ -r "$f" ]] || {
            echo "error: cannot read $f" >&2
            exit 1
        }
    done
    facts="$(cat "$FACTS_FILE")"
    probe="$(cat "$PROBE_FILE")"
    node="$(jq -r '.toplevel | sub("^/nix/store/[a-z0-9]+-nixos-system-"; "") | sub("-[0-9].*$"; "")' <<<"$facts")"
else
    # `<path>#<host>`. The default is THIS checkout, not the caller's cwd, so
    # it means the same thing from anywhere.
    [[ -n "$FLAKE_REF" ]] || FLAKE_REF="$(cd "$SCRIPT_DIR/.." && pwd)#$(hostname)"
    if [[ "$FLAKE_REF" != *"#"* ]]; then
        echo "error: --flake must be <path>#<host>, got: $FLAKE_REF" >&2
        exit 1
    fi
    flake_path="${FLAKE_REF%%#*}"
    node="${FLAKE_REF#*#}"

    # A dirty tree evaluates to a closure no commit produced, so the fleet
    # manifest cannot contain it and this host will report deploy state
    # 'unmanaged' until the next switch from a clean tree. Expected while
    # iterating; worth knowing. safe.directory because this runs as root
    # against a checkout owned by the user, which git otherwise refuses.
    if dirty="$(git -c safe.directory='*' -C "$flake_path" status --porcelain 2>/dev/null)" && [[ -n "$dirty" ]]; then
        say "warning: $flake_path has uncommitted changes; after this switch the host will"
        say "  report deploy state 'unmanaged' until it is switched from a clean tree."
        say ""
    fi

    say "Preflight: evaluating ${FLAKE_REF} (nothing is built or applied)..."
    eval_err="$(mktemp)"
    trap 'rm -f "$eval_err"' EXIT
    if ! facts="$(nix eval --json "${flake_path}#lib.deployFacts.nixos.\"${node}\"" 2>"$eval_err")"; then
        echo "error: could not evaluate the target:" >&2
        sed 's/^/  /' "$eval_err" >&2
        exit 1
    fi

    # Validated before the names are interpolated into the probe below.
    if ! why="$(dg_validate_facts "$facts")"; then
        echo "error: $why" >&2
        exit 1
    fi

    want_procs=0
    [[ "$(jq '.processes | length' <<<"$facts")" -gt 0 ]] && want_procs=1
    # The exact bytes colmena-apply-drifted.sh sends over SSH, run here.
    if ! probe="$(dg_probe_script "$(dg_fact_units "$facts")" "$want_procs" | /bin/sh -s 2>/dev/null)"; then
        echo "error: the local probe failed" >&2
        exit 1
    fi
fi

dg_classify "$facts" "$probe"

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------
if [[ "$DG_STATE" == noprobe ]]; then
    echo "error: could not read /run/current-system; the verdict is unknown" >&2
    exit 1
fi

say ""
say "Preflight result for ${node}"

if [[ "$DG_STATE" == current ]]; then
    say "  already running the target generation; a switch has nothing to do."
    [[ -n "$DG_OWED" ]] && say "  reboot owed: $DG_OWED"
    say ""
    say "VERDICT: safe to switch."
    exit 0
fi

# Each rule: what it found, and whether the caller overrode it. An override is
# still reported -- it says "I accept this", not "do not tell me".
held=()
overridden=()
rule() {
    local flag="$1" allow="$2"
    shift 2
    local entry
    for entry in "$@"; do
        [[ -n "$entry" ]] || continue
        if [[ "$allow" -eq 1 ]]; then
            overridden+=("$entry (overridden by $flag)")
        else
            held+=("$entry")
        fi
    done
}
rule --allow-unsafe-switch "$ALLOW_UNSAFE_SWITCH" "$DG_HOLD_SYSTEMD"
rule --allow-kernel-switch "$ALLOW_KERNEL_SWITCH" "$DG_HOLD_KERNEL"
rule --allow-critical-restart "$ALLOW_CRITICAL_RESTART" ${DG_HOLD_CRITICAL[@]+"${DG_HOLD_CRITICAL[@]}"}
rule --allow-process-change "$ALLOW_PROCESS_CHANGE" ${DG_HOLD_PROCESS[@]+"${DG_HOLD_PROCESS[@]}"}

for entry in ${held[@]+"${held[@]}"}; do
    say "  HOLD      $entry"
done
for entry in ${overridden[@]+"${overridden[@]}"}; do
    say "  ALLOWED   $entry"
done
for entry in ${DG_CRITICAL_UNKNOWN[@]+"${DG_CRITICAL_UNKNOWN[@]}"}; do
    say "  UNKNOWN   $entry"
done
for entry in ${DG_INFO[@]+"${DG_INFO[@]}"}; do
    say "  note      $entry"
done
if [[ ${#held[@]} -eq 0 && ${#overridden[@]} -eq 0 ]]; then
    say "  nothing holds: systemd, the booted kernel, critical units and running"
    say "  critical processes are all unchanged by this generation."
fi
[[ -n "$DG_OWED" ]] && say "  reboot owed already: $DG_OWED"

if [[ ${#held[@]} -gt 0 ]]; then
    say ""
    say "VERDICT: do NOT switch live."
    say ""
    say "  Stage it and reboot instead; the reboot reaches the new generation"
    say "  without re-execing a running PID 1 or swapping software under a live"
    say "  session:"
    say ""
    say "    sudo nixos-rebuild boot --flake ${FLAKE_REF:-.#${node}}"
    say "    sudo reboot"
    exit 10
fi

say ""
say "VERDICT: safe to switch."
exit 0
