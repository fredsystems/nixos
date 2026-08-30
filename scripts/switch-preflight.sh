#!/usr/bin/env bash
#
# switch-preflight.sh -- decide whether `nixos-rebuild switch` is safe to run
# live on this machine, or whether the new generation must be reached by
# `boot` + reboot instead.
#
# WHY THIS EXISTS
#
# switch-to-configuration can wedge PID 1 hard enough that the machine cannot
# even reboot. The sequence, observed on maranello 2026-08-29 20:21:59 and
# repeatedly on Daytona:
#
#   1. s-t-c stops a network daemon in its stop pass, so the LAN goes away.
#   2. s-t-c asks PID 1 to `daemon-reexec`, which it does whenever systemd's
#      store path changed -- a glibc/stdenv mass rebuild is enough, the systemd
#      version does not have to move at all.
#   3. On re-exec PID 1 re-runs its generators. systemd-fstab-generator calls
#      chase()/stat() on every fstab entry, including NFS mounts.
#   4. Those mounts are `hard`, the server is now unreachable, and stat()
#      blocks forever. The generator sandbox times out after 90s and
#      safe_fork(FORK_WAIT) reports it as -EPROTO ("Protocol error").
#   5. Generators are mandatory, so PID 1 prints `Freezing execution.` and
#      stops. It is alive but deaf: no D-Bus, nothing starts or stops, and
#      `reboot` is itself a D-Bus call to PID 1, so it hangs too. The box
#      needs SysRq or the power button.
#
# Upstream: https://github.com/NixOS/nixpkgs/issues/375376 (open).
#
# The point of this script is that all three preconditions are knowable BEFORE
# anything is activated, so this is a decision, not a guess. `nixos-rebuild
# dry-activate` reports exactly what the real switch would do, including the
# literal line `would restart systemd` for the daemon-reexec.
#
# THE PREDICATE
#
# Blocks the switch when ALL of these hold:
#
#   REEXEC   dry-activate says `would restart systemd`
#   NETFS    there are live NFS/CIFS mounts whose stat() could block
#   HANG     the network is going to disappear under those mounts, either
#            because a watched network unit is in the stop/restart set, or
#            because the fileserver is ALREADY unreachable right now
#
# Any one of these missing and the deadlock cannot form, so the switch is
# allowed. That is deliberate: a predicate that fires on every mass rebuild
# would be ignored within a week.
#
# DEFERRED RESTARTS
#
# features/common/system/default.nix sets `reloadIfChanged` on NetworkManager
# so activation stops taking the network down. The cost is that the running
# NetworkManager stays on the OLD store path until something restarts it, so a
# NetworkManager update -- including a security fix -- is not live yet. That is
# not inferred: `--deferred` compares each watched unit's configured ExecStart
# against the binary the running MainPID actually has open via /proc, and
# reports the mismatch. A reboot clears it; so does `systemctl restart <unit>`,
# which picks up the new ExecStart because activation already ran
# `daemon-reload` regardless of whether it reloaded or restarted the unit.
#
# Usage:
#   scripts/switch-preflight.sh                    # build + dry-activate + verdict
#   scripts/switch-preflight.sh --flake .#maranello
#   scripts/switch-preflight.sh --deferred         # only the deferred-restart report
#   scripts/switch-preflight.sh --plan-file FILE   # classify an existing dry-activate log
#   scripts/switch-preflight.sh --quiet            # verdict only, no explanation
#
# Exit codes:
#   0   safe to `switch`
#   10  UNSAFE to switch live -- use `nixos-rebuild boot` and reboot
#   1   error

set -euo pipefail

# Units whose stop/restart takes the LAN away. Anything here appearing in
# dry-activate's stop or restart set means the NFS mounts lose their server
# mid-activation. wpa_supplicant is on the list even though the 2026-08-29
# journal shows s-t-c did not stop it -- if that ever changes, this catches it
# rather than us rediscovering the deadlock the hard way.
WATCHED_NET_UNITS=(
    NetworkManager.service
    wpa_supplicant.service
    systemd-networkd.service
    dhcpcd.service
)

FLAKE_REF=""
PLAN_FILE=""
DEFERRED_ONLY=0
QUIET=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --flake)
            [[ $# -ge 2 ]] || {
                echo "error: --flake needs a value" >&2
                exit 1
            }
            FLAKE_REF="$2"
            shift
            ;;
        --plan-file)
            [[ $# -ge 2 ]] || {
                echo "error: --plan-file needs a value" >&2
                exit 1
            }
            PLAN_FILE="$2"
            shift
            ;;
        --deferred) DEFERRED_ONLY=1 ;;
        --quiet) QUIET=1 ;;
        -h | --help)
            # Print the header block by structure, not by line number, so it
            # cannot silently truncate as the header grows. Same trick as
            # colmena-apply-drifted.sh.
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

# Extract the `/nix/store/<hash>-<name>` prefix from a path, discarding
# anything below it. Two paths sharing this prefix are the same build.
store_prefix() {
    grep -oE '/nix/store/[a-z0-9]{32}-[^/]+' <<<"${1:-}" | head -1 || true
}

# ---------------------------------------------------------------------------
# Deferred restarts: configured ExecStart vs the binary the process really has
# ---------------------------------------------------------------------------
#
# Prints one line per unit still running a superseded binary. Returns 0 if any
# were found, 1 if everything is current, so callers can branch on it.
DEFERRED_STALE=()
DEFERRED_UNREADABLE=()

# Populates the two arrays above. Deliberately NOT written to be called in a
# command substitution: `$(...)` runs the function in a subshell, so the arrays
# would be assigned in a child and silently discarded, and the caller would see
# an empty "unreadable" list and report a false all-clear. Call it directly and
# read the globals.
#
# The staleness test is "is the binary this process actually has open still part
# of /run/current-system's closure?", NOT "does ExecStart match /proc/exe".
# The latter looks obvious and is wrong: many NixOS units have a generated
# `unit-script-<name>-start` wrapper as their ExecStart, which then execs the
# real binary, so the two paths never match and every such unit reports as
# permanently stale. wpa_supplicant.service is one of them.
scan_deferred_restarts() {
    local unit state pid have requisites

    DEFERRED_STALE=()
    DEFERRED_UNREADABLE=()

    requisites="$(mktemp)" || return 0
    if ! nix-store -q --requisites /run/current-system >"$requisites" 2>/dev/null; then
        rm -f "$requisites"
        return 0
    fi

    for unit in "${WATCHED_NET_UNITS[@]}"; do
        state="$(systemctl show -p ActiveState --value "$unit" 2>/dev/null || true)"
        [[ "$state" == "active" ]] || continue

        pid="$(systemctl show -p MainPID --value "$unit" 2>/dev/null || true)"
        [[ -n "$pid" && "$pid" != "0" ]] || continue

        # /proc/<pid>/exe is only readable for another user's process as root.
        # If we cannot read it we do NOT know whether the unit is current, and
        # staying silent would read as an all-clear. Record it instead.
        have="$(store_prefix "$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)")"

        if [[ -z "$have" ]]; then
            DEFERRED_UNREADABLE+=("$unit")
            continue
        fi

        # Still in the current generation's closure => running current code.
        grep -qxF "$have" "$requisites" && continue

        DEFERRED_STALE+=("$(printf '  %s (pid %s)\n    still running: %s\n    which is not part of the current generation' "$unit" "$pid" "$have")")
    done

    rm -f "$requisites"
}

print_deferred_section() {
    [[ ${#DEFERRED_STALE[@]} -gt 0 ]] || return 0
    say ""
    say "NOTE: these units changed but were reloaded, not restarted, so they are"
    say "still running the previous binary:"
    say ""
    printf '%s\n' "${DEFERRED_STALE[@]}"
    say ""
    say "  This is features/common/system/default.nix's reloadIfChanged doing its"
    say "  job -- activation no longer drops the network. But the update is NOT"
    say "  live yet; if it was a security fix you are not patched."
    say ""
    say "  Pick one up when convenient (both briefly bounce the link):"
    say "    sudo systemctl restart NetworkManager"
    say "    sudo reboot"
}

warn_if_deferred_unknown() {
    [[ ${#DEFERRED_UNREADABLE[@]} -gt 0 ]] || return 0
    say ""
    say "WARNING: could not read /proc/<pid>/exe for: ${DEFERRED_UNREADABLE[*]}"
    say "  Deferred-restart state for those units is UNKNOWN, not clean."
    say "  Re-run with sudo for an authoritative answer."
}

if [[ "$DEFERRED_ONLY" -eq 1 ]]; then
    scan_deferred_restarts
    if [[ ${#DEFERRED_STALE[@]} -eq 0 && ${#DEFERRED_UNREADABLE[@]} -eq 0 ]]; then
        say "No deferred restarts: every watched network unit is running its configured binary."
    fi
    print_deferred_section
    warn_if_deferred_unknown
    exit 0
fi

# dry-activate applies nothing, but switch-to-configuration still requires
# root to inspect the running system. Refuse early rather than fail deep in
# the build with a confusing error. --plan-file classifies an already-captured
# log and does not invoke nixos-rebuild, so it is exempt.
if [[ -z "$PLAN_FILE" && "$(id -u)" -ne 0 ]]; then
    echo "error: preflight must run as root (dry-activate activates nothing, but needs root)" >&2
    echo "  try: sudo $0${FLAKE_REF:+ --flake $FLAKE_REF}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# NETFS: live network filesystems whose stat() can block PID 1's generators
# ---------------------------------------------------------------------------
netfs_targets=()
netfs_servers=()

if command -v findmnt >/dev/null 2>&1; then
    while IFS=$'\t' read -r target _source options; do
        [[ -n "$target" ]] || continue
        netfs_targets+=("$target")
        # `addr=` is the resolved server address the kernel is actually using,
        # which is what will time out. Prefer it over parsing the source spec.
        addr="$(grep -oE '(^|,)addr=[^,]+' <<<"$options" | head -1 | cut -d= -f2 || true)"
        [[ -n "$addr" ]] && netfs_servers+=("$addr")
    done < <(findmnt -t nfs,nfs4,cifs -o TARGET,SOURCE,OPTIONS --noheadings --pairs 2>/dev/null |
        sed -n 's/^TARGET="\([^"]*\)" SOURCE="\([^"]*\)" OPTIONS="\([^"]*\)"$/\1\t\2\t\3/p')
fi

# Deduplicate servers without requiring bash 4 associative arrays.
if [[ ${#netfs_servers[@]} -gt 0 ]]; then
    mapfile -t netfs_servers < <(printf '%s\n' "${netfs_servers[@]}" | sort -u)
fi

# A server we cannot reach RIGHT NOW is already the hang condition: the
# generator will block on it during the re-exec no matter what activation does
# to the network. 2049 is NFS; 445 is SMB. Two seconds is generous for a LAN.
unreachable_servers=()
for srv in ${netfs_servers[@]+"${netfs_servers[@]}"}; do
    reachable=1
    for port in 2049 445; do
        if timeout 2 bash -c "exec 3<>/dev/tcp/${srv}/${port}" 2>/dev/null; then
            reachable=0
            break
        fi
    done
    [[ "$reachable" -eq 0 ]] || unreachable_servers+=("$srv")
done

# ---------------------------------------------------------------------------
# The activation plan
# ---------------------------------------------------------------------------
if [[ -n "$PLAN_FILE" ]]; then
    [[ -r "$PLAN_FILE" ]] || {
        echo "error: cannot read plan file: $PLAN_FILE" >&2
        exit 1
    }
    plan="$(cat "$PLAN_FILE")"
else
    if [[ -z "$FLAKE_REF" ]]; then
        FLAKE_REF=".#$(hostname)"
    fi
    command -v nixos-rebuild >/dev/null 2>&1 || {
        echo "error: nixos-rebuild not on PATH" >&2
        exit 1
    }
    say "Preflight: building and dry-activating ${FLAKE_REF} (nothing is applied)..."
    plan_err="$(mktemp)"
    trap 'rm -f "$plan_err"' EXIT
    if ! plan="$(nixos-rebuild dry-activate --flake "$FLAKE_REF" 2>"$plan_err")"; then
        echo "error: dry-activate failed:" >&2
        sed 's/^/  /' "$plan_err" >&2
        exit 1
    fi
    # nixos-rebuild puts the build log on stderr and the plan on stdout, but
    # switch-to-configuration's own "would ..." lines go to stderr. Consider
    # both so the predicate cannot silently see an empty plan.
    plan="${plan}"$'\n'"$(cat "$plan_err")"
fi

# ---------------------------------------------------------------------------
# Classify
# ---------------------------------------------------------------------------
reexec=1
grep -qE '^would restart systemd$' <<<"$plan" && reexec=0

# Only the stop and restart sets take the daemon down. A reload does not, which
# is the entire point of the reloadIfChanged change, so it must not count here.
disruptive_units="$(grep -E '^would (stop|restart) the following units: ' <<<"$plan" |
    sed 's/^would \(stop\|restart\) the following units: //' | tr ',' '\n' | sed 's/^ *//;s/ *$//' || true)"

net_at_risk=()
for unit in "${WATCHED_NET_UNITS[@]}"; do
    grep -qxF "$unit" <<<"$disruptive_units" && net_at_risk+=("$unit")
done

has_netfs=$([[ ${#netfs_targets[@]} -gt 0 ]] && echo 0 || echo 1)
has_netrisk=$([[ ${#net_at_risk[@]} -gt 0 ]] && echo 0 || echo 1)
has_unreachable=$([[ ${#unreachable_servers[@]} -gt 0 ]] && echo 0 || echo 1)

say ""
say "Preflight result"
say "  systemd daemon-reexec:      $([[ "$reexec" -eq 0 ]] && echo "YES (would restart systemd)" || echo "no")"
say "  live NFS/CIFS mounts:       $([[ "$has_netfs" -eq 0 ]] && echo "${#netfs_targets[@]}" || echo "none")"
say "  network units stopped:      $([[ "$has_netrisk" -eq 0 ]] && printf '%s' "${net_at_risk[*]}" || echo "none")"
say "  fileservers unreachable:    $([[ "$has_unreachable" -eq 0 ]] && printf '%s' "${unreachable_servers[*]}" || echo "none")"

if [[ "$reexec" -eq 0 && "$has_netfs" -eq 0 && ("$has_netrisk" -eq 0 || "$has_unreachable" -eq 0) ]]; then
    say ""
    say "VERDICT: do NOT switch live."
    say ""
    say "  This activation re-execs PID 1 while the network filesystems above can"
    say "  stall. That is the exact combination that freezes PID 1 (nixpkgs#375376):"
    say "  the machine would survive the switch only to become unresponsive to"
    say "  systemctl AND to reboot, needing SysRq or a power cycle."
    say ""
    say "  Everything is already built. Reach the new generation via a reboot,"
    say "  which runs the shutdown under the current healthy PID 1:"
    say ""
    say "    sudo nixos-rebuild boot --flake ${FLAKE_REF:-.#$(hostname)}"
    say "    sudo reboot"
    exit 10
fi

say ""
say "VERDICT: safe to switch."
scan_deferred_restarts
print_deferred_section
warn_if_deferred_unknown
exit 0
