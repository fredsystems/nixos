# shellcheck shell=bash
#
# deploy-guard.sh -- the shared answer to "can this node take a live
# `switch`, or must it be reached with `boot` + reboot?"
#
# Sourced, not executed, by:
#
#   scripts/switch-preflight.sh       the local machine (desktops, updatenix)
#   scripts/colmena-apply-drifted.sh  every colmena node, over SSH
#
# Both used to carry their own copy of this logic and drifted badly: the
# desktop copy held only when systemd re-exec'd AND `findmnt` saw a live NFS
# mount AND the network was going away -- and `findmnt -t nfs` does not see an
# idle x-systemd.automount share, which is how every NAS mount here is
# declared, so it waved through exactly the re-exec the server copy had
# learned to refuse. There is now one copy. Changing a rule here changes it
# for every node.
#
# THE TWO HALVES
#
#   target   what the closure WOULD install. Evaluated, never built, by
#            flake/lib/deploy-facts.nix (`.#lib.deployFacts.{nixos,colmena}`).
#   running  what the node IS running. Collected by DG_PROBE_BODY, a POSIX sh
#            script that runs identically under `/bin/sh -s` locally and over
#            SSH, so the local and remote probes are the same bytes.
#
# dg_classify compares the two. It is pure (strings in, globals out), which is
# what lets scripts/tests/deploy-guard-test.sh exercise every rule with
# fixtures instead of a fleet.
#
# THE HOLD RULES
#
#   systemd    systemd.package's store path moves. `switch` would re-exec PID 1
#              in place, and a re-exec that hangs in a generator freezes PID 1
#              hard enough that `reboot` hangs too (NixOS/nixpkgs#375376).
#              Store path, not version: a glibc/stdenv mass rebuild re-execs
#              PID 1 just the same.
#   kernel     the kernel image or the SET of module packages differs from what
#              the node BOOTED. `switch` cannot change the running kernel; it
#              would report success with the update not live.
#   critical   a deployment.criticalUnits unit file changes, so activation
#              would restart it (atticd, DNS -- other nodes' deploys depend on
#              them).
#   process    a deployment.criticalProcesses package is RUNNING at a different
#              VERSION than the target's (the compositor you are logged into).
#
# Anything that cannot be read counts as changed. Wrongly holding costs a
# reboot; wrongly switching can cost a frozen box. The one exception is a
# critical unit that cannot be compared: that is reported but not held,
# because the failure it guards against is loud and recoverable.
#
# AFTER THE SWITCH
#
# DG_SCAN_BODY + dg_scan_report list every process still running a binary
# that is not part of the new /run/current-system: system daemons that
# activation reloaded rather than restarted (NetworkManager, by design -- see
# features/common/system/default.nix), and the apps open in your session.
# Nothing is held for those; they are what to restart when convenient.

# Unit names, package names: validated before they are interpolated into a
# probe script. What systemd and Nix themselves permit; anything else is a
# mistake or an injection attempt and must not reach an `ssh` command line.
DG_UNIT_NAME_RE='^[A-Za-z0-9@:._\-]+\.[a-z]+$'
DG_PNAME_RE='^[A-Za-z0-9._+\-]+$'

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

# "systemd-260.5" out of "/nix/store/<hash>-systemd-260.5[/...]". Display and
# name parsing only -- hold decisions on store paths compare full paths.
dg_store_name() {
    local p="${1#/nix/store/}"
    p="${p#*-}"
    printf '%s' "${p%%/*}"
}

# "a -> b", or "a (rebuilt, same version)" when only the hash moved. Without
# the second form a mass-rebuild hold reads "systemd-260.5 -> systemd-260.5",
# which looks like a bug rather than the reason.
dg_describe_change() {
    local from to
    from="$(dg_store_name "$1")"
    to="$(dg_store_name "$2")"
    if [[ "$from" == "$to" ]]; then
        printf '%s (rebuilt, same version)' "$to"
    else
        printf '%s -> %s' "$from" "$to"
    fi
}

# Read one key=value field out of a probe block. `unit:` keys contain a `.`,
# so this is an exact prefix match rather than a regex.
dg_probe_field() {
    awk -v k="$2" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' <<<"$1"
}

# Print the arguments that do not match regex $1, space-separated.
dg_bad_names() {
    local re="$1" n bad=()
    shift
    for n in "$@"; do
        [[ "$n" =~ $re ]] || bad+=("$n")
    done
    printf '%s' "${bad[*]}"
}

# Space-separated critical unit names out of a per-node facts object.
dg_fact_units() {
    jq -r '(.critical // {}) | keys | join(" ")' <<<"$1"
}

# Validate the names in a per-node facts object. Prints a reason and returns
# 1 if any would be unsafe to interpolate.
dg_validate_facts() {
    local units pnames bad
    units="$(dg_fact_units "$1")"
    pnames="$(jq -r '[(.processes // {})[] | .pnames] | join(" ")' <<<"$1")"
    # shellcheck disable=SC2086 # word-splitting the space-joined lists is the point
    bad="$(dg_bad_names "$DG_UNIT_NAME_RE" $units)"
    if [[ -n "$bad" ]]; then
        echo "deployment.criticalUnits contains unusable unit name(s): $bad"
        return 1
    fi
    # shellcheck disable=SC2086
    bad="$(dg_bad_names "$DG_PNAME_RE" $pnames)"
    if [[ -n "$bad" ]]; then
        echo "deployment.criticalProcesses contains unusable package name(s): $bad"
        return 1
    fi
}

# awk library shared by every awk program below. parse_drv() splits a
# derivation name exactly the way builtins.parseDrvName does -- the version
# starts at the first dash-separated component that begins with a digit -- so
# "discord-unwrapped-1.0.161" is pname "discord-unwrapped", version
# "1.0.161", and both sides of every version comparison are split by the same
# rule.
DG_AWK_LIB='
function store_name(p,   s) {
  s = p
  sub(/^\/nix\/store\/[a-z0-9]+-/, "", s)
  sub(/\/.*/, "", s)
  return s
}
function parse_drv(n,   k, i, c, parts) {
  k = split(n, parts, "-")
  PN = parts[1]; PV = ""
  for (i = 2; i <= k; i++) {
    if (parts[i] ~ /^[0-9]/) {
      PV = parts[i]
      for (c = i + 1; c <= k; c++) PV = PV "-" parts[c]
      return
    }
    PN = PN "-" parts[i]
  }
}
'

# ---------------------------------------------------------------------------
# The probe scripts (POSIX sh, run on the node)
# ---------------------------------------------------------------------------
#
# Single-quoted throughout: every $ must expand on the NODE. Run them with
# `/bin/sh -s` and the script on stdin, never as an ssh command argument --
# that would run them in the account's login shell, which here is zsh, and zsh
# does not word-split unquoted expansions (`for u in $CRITICAL_UNITS` ran once
# with the whole list; found by testing, not by reading).
#
# DEPLOY_GUARD_TEST_ROOT re-roots /run, /nix/var and /proc so the test suite
# can run these exact bytes against a fixture tree. Unset on every real node.

# Enumerate running processes as `proc <pid> <uid> <unit> <store-prefix>`,
# plus `unreadable <pid>` for a process whose binary cannot be attributed.
#
# Attributed by the store path of the binary, never by name: `comm` is
# truncated to 15 bytes (a wrapped Hyprland is `.Hyprland-wrapp`), and
# Electron apps run out of opt/ under a capitalised name. /proc/<pid>/exe is
# authoritative; argv[0] is the fallback only when exe is unreadable (a
# non-root caller, or a non-dumpable process such as Hyprland) AND argv[0] is
# itself a store path. A process with no cmdline is a kernel thread or a zombie
# and is skipped. An exe outside /nix/store (container processes, /usr/bin in
# a Docker image) is not ours to judge and is skipped.
# shellcheck disable=SC2016
DG_SH_PROCS='
dg_procs() {
  for d in "$R"/proc/[0-9]*; do
    a0=$(tr "\0" "\n" < "$d/cmdline" 2>/dev/null | head -n 1)
    [ -n "$a0" ] || continue
    if e=$(readlink "$d/exe" 2>/dev/null) && [ -n "$e" ]; then
      src=$e
    else
      case "$a0" in
        /nix/store/*) src=$a0 ;;
        *) printf "unreadable %s\n" "${d##*/}"; continue ;;
      esac
    fi
    sp=$(printf "%s\n" "$src" | grep -oE "^/nix/store/[a-z0-9]{32}-[^/ ]+" | head -n 1)
    [ -n "$sp" ] || continue
    uid=$(awk "/^Uid:/ { print \$2; exit }" "$d/status" 2>/dev/null)
    unit=$(sed -n "s|^0::.*/||p" "$d/cgroup" 2>/dev/null | head -n 1)
    printf "proc %s %s %s %s\n" "${d##*/}" "${uid:--}" "${unit:--}" "$sp"
  done
}
'

# The pre-switch probe. Emits key=value lines so a new field cannot silently
# shift the meaning of an existing one; `unit:<name>` is namespaced so a unit
# called `kernel` cannot collide with the kernel field. An empty value or "?"
# means "could not be read", which every rule treats as unknown, never as no.
#
# Supplied with CRITICAL_UNITS and WANT_PROCS by dg_probe_script.
# shellcheck disable=SC2016
DG_PROBE_BODY="$DG_SH_PROCS"'
R="${DEPLOY_GUARD_TEST_ROOT:-}"
printf "toplevel=%s\n" "$(readlink -f "$R/run/current-system")"
printf "booted=%s\n" "$(readlink -f "$R/run/booted-system" 2>/dev/null)"
printf "booted_systemd=%s\n" "$(readlink -f "$R/run/booted-system/systemd" 2>/dev/null)"
printf "systemd=%s\n" "$(readlink -f "$R/run/current-system/systemd" 2>/dev/null)"

# The system profile is what both `boot` and `switch` update: the generation
# the bootloader will start. Differing from /run/current-system is the exact
# signature of a staged-but-not-activated closure.
printf "profile=%s\n" "$(readlink -f "$R/nix/var/nix/profiles/system" 2>/dev/null)"

# Kernel facts are about the BOOTED generation: `switch` moves
# current-system/kernel without the running kernel changing at all. Modules
# are the sorted store references of the module tree -- the packages it was
# assembled from, which is exactly the list deploy-facts.nix evaluates.
# LC_ALL=C so the order is byte order, matching builtins.lessThan. Empty if
# nix-store fails, never a partial list.
mod_refs() {
  t=$(readlink -f "$1" 2>/dev/null) || return 0
  [ -n "$t" ] || return 0
  r=$(nix-store -q --references "$t" 2>/dev/null) || return 0
  printf "%s\n" "$r" | grep . | LC_ALL=C sort | paste -sd " " -
}
printf "kernel=%s\n" "$(readlink -f "$R/run/booted-system/kernel" 2>/dev/null)"
printf "modules=%s\n" "$(mod_refs "$R/run/booted-system/kernel-modules")"
printf "current_kernel=%s\n" "$(readlink -f "$R/run/current-system/kernel" 2>/dev/null)"
printf "current_modules=%s\n" "$(mod_refs "$R/run/current-system/kernel-modules")"

# The unit DERIVATION path, not the file inside it, so it compares directly
# against config.systemd.units.<u>.unit. "absent" is an answer, not "?": a
# unit the running generation lacks will be STARTED, not restarted.
for u in $CRITICAL_UNITS; do
  f="$R/run/current-system/etc/systemd/system/$u"
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

# Running binaries, deduplicated to store prefixes. Only collected when the
# node declares a critical process: it walks all of /proc, which a server
# with none has no use for.
if [ "$WANT_PROCS" = 1 ]; then
  dg_procs | awk "
    \$1 == \"proc\" && !seen[\$5]++ { print \"proc=\" \$5 }
    \$1 == \"unreadable\" { u++ }
    END { print \"proc_unreadable=\" u + 0 }"
fi
'

# The post-switch scan: the new generation's closure plus every running
# process, for dg_scan_report to diff. The closure is shipped whole rather
# than matched on the node so the matching rules live in exactly one place
# (DG_AWK_LIB). `scan=done` last, so a scan that died partway -- or an SSH
# session that never ran -- cannot read as "nothing stale".
# shellcheck disable=SC2016
DG_SCAN_BODY="$DG_SH_PROCS"'
R="${DEPLOY_GUARD_TEST_ROOT:-}"
cur=$(readlink -f "$R/run/current-system")
if ! req=$(nix-store -q --requisites "$cur" 2>/dev/null); then
  echo "scan=error could not list the closure of $cur"
  exit 0
fi
printf "%s\n" "$req" | sed "s/^/closure /"

# Every system generation still on disk, plus the booted one. A running binary
# that is in none of them was never part of the system -- a `nix develop`
# shell, `nix run`, a dev build -- so it is not stale, just foreign. Without
# this a dev shell'"'"'s newer bash read as "bash 5.3p20 -> 5.3p15".
old=$(nix-store -q --requisites "$R"/nix/var/nix/profiles/system-*-link "$R/run/booted-system" 2>/dev/null) || old=""
printf "%s\n" "$old" | grep . | sed "s/^/old /"
dg_procs
echo "scan=done"
'

# The probe script for a node: its critical units and whether to walk /proc,
# prepended as assignments. Callers must have run dg_validate_facts first --
# the unit names are interpolated into a single-quoted shell string.
dg_probe_script() {
    local units="$1" want_procs="$2"
    printf "CRITICAL_UNITS='%s'\nWANT_PROCS='%s'\n%s\n" "$units" "$want_procs" "$DG_PROBE_BODY"
}

# The scan script. A function for symmetry with dg_probe_script.
dg_scan_script() {
    printf '%s\n' "$DG_SCAN_BODY"
}

# ---------------------------------------------------------------------------
# Classification (pure)
# ---------------------------------------------------------------------------
#
# dg_classify <facts-json> <probe-block>
#
# <facts-json> is ONE node's object from .#lib.deployFacts; <probe-block> is
# DG_PROBE_BODY's output from that node. Sets:
#
#   DG_STATE            noprobe | current | drifted
#   DG_RUNNING          the node's /run/current-system
#   DG_PROFILE          the node's system profile
#   DG_OWED             why a reboot is ALREADY owed, independent of this
#                       deploy (staged generation, kernel/systemd switched
#                       into live); empty if none
#   DG_HOLD_SYSTEMD     reason, or empty
#   DG_HOLD_KERNEL      reason, or empty
#   DG_HOLD_CRITICAL    array of reasons
#   DG_HOLD_PROCESS     array of reasons
#   DG_CRITICAL_UNKNOWN array: critical units that could not be compared
#   DG_INFO             array: observations that do not hold anything
#
# Holds are only computed for a drifted node; a current node has nothing to
# activate.
# shellcheck disable=SC2034 # every DG_* global is read by the callers
dg_classify() {
    local facts="$1" probe="$2"
    local expected running running_systemd booted_systemd booted_kernel booted_modules
    local current_kernel current_modules target_systemd target_kernel target_modules
    local unit have want reason added m units

    DG_STATE=""
    DG_RUNNING=""
    DG_PROFILE=""
    DG_OWED=""
    DG_HOLD_SYSTEMD=""
    DG_HOLD_KERNEL=""
    DG_HOLD_CRITICAL=()
    DG_HOLD_PROCESS=()
    DG_CRITICAL_UNKNOWN=()
    DG_INFO=()

    expected="$(jq -r '.toplevel // ""' <<<"$facts")"
    if [[ -z "$expected" ]]; then
        echo "dg_classify: facts carry no toplevel" >&2
        return 1
    fi

    running="$(dg_probe_field "$probe" toplevel)"
    DG_RUNNING="$running"
    DG_PROFILE="$(dg_probe_field "$probe" profile)"

    # The probe ran but produced nothing usable. Treating that as drift would
    # deploy on a failed probe; treating it as current would skip the node
    # forever.
    if [[ -z "$running" ]]; then
        DG_STATE=noprobe
        return 0
    fi

    running_systemd="$(dg_probe_field "$probe" systemd)"
    booted_systemd="$(dg_probe_field "$probe" booted_systemd)"
    booted_kernel="$(dg_probe_field "$probe" kernel)"
    booted_modules="$(dg_probe_field "$probe" modules)"
    current_kernel="$(dg_probe_field "$probe" current_kernel)"
    current_modules="$(dg_probe_field "$probe" current_modules)"

    # Reboot already owed. A staged generation is one way; the other is a
    # generation that IS running but was switched into live across a kernel or
    # systemd change -- profile and current-system agree, so only comparing
    # against /run/booted-system shows it. Same thing nixos-needsreboot flags.
    # Each comparison needs both of its paths, so a partial probe cannot
    # schedule a reboot on its own.
    if [[ -n "$DG_PROFILE" && "$DG_PROFILE" != "$running" ]]; then
        DG_OWED="staged generation"
    else
        if [[ -n "$booted_kernel" && -n "$current_kernel" && "$booted_kernel" != "$current_kernel" ]] ||
            [[ -n "$booted_modules" && -n "$current_modules" && "$booted_modules" != "$current_modules" ]]; then
            DG_OWED="kernel"
        fi
        if [[ -n "$booted_systemd" && -n "$running_systemd" && "$booted_systemd" != "$running_systemd" ]]; then
            DG_OWED="${DG_OWED:+$DG_OWED, }systemd $(dg_describe_change "$booted_systemd" "$running_systemd")"
        fi
    fi

    if [[ "$running" == "$expected" ]]; then
        DG_STATE=current
        return 0
    fi
    DG_STATE=drifted

    # systemd
    target_systemd="$(jq -r '.systemd // ""' <<<"$facts")"
    if [[ -z "$running_systemd" || -z "$target_systemd" ]]; then
        DG_HOLD_SYSTEMD="running systemd unreadable, treated as changed"
    elif [[ "$running_systemd" != "$target_systemd" ]]; then
        DG_HOLD_SYSTEMD="systemd $(dg_describe_change "$running_systemd" "$target_systemd")"
    fi

    # kernel, against what the node BOOTED
    target_kernel="$(jq -r '.kernel.image // ""' <<<"$facts")"
    target_modules="$(jq -r '.kernel.modules // ""' <<<"$facts")"
    if [[ -z "$booted_kernel" || -z "$booted_modules" || -z "$target_kernel" || -z "$target_modules" ]]; then
        DG_HOLD_KERNEL="booted kernel unreadable, treated as changed"
    elif [[ "$booted_kernel" != "$target_kernel" ]]; then
        DG_HOLD_KERNEL="kernel $(dg_describe_change "$booted_kernel" "$target_kernel")"
    elif [[ "$booted_modules" != "$target_modules" ]]; then
        # Name only what is new: both full sets would be two lines of store
        # paths differing in one entry.
        added=""
        for m in $target_modules; do
            [[ " $booted_modules " == *" $m "* ]] || added+=" $(dg_store_name "$m")"
        done
        DG_HOLD_KERNEL="kernel modules change:${added:- (removed only)}"
    fi

    # critical units: switch-to-configuration restarts a unit exactly when its
    # unit file changed, so this is a decision, not an estimate.
    units="$(dg_fact_units "$facts")"
    for unit in $units; do
        have="$(dg_probe_field "$probe" "unit:${unit}")"
        want="$(jq -r --arg u "$unit" '.critical[$u].path // ""' <<<"$facts")"
        reason="$(jq -r --arg u "$unit" '.critical[$u].reason // "no reason recorded"' <<<"$facts")"
        if [[ -z "$have" || "$have" == "?" || -z "$want" ]]; then
            DG_CRITICAL_UNKNOWN+=("could not compare $unit (running='${have:-?}')")
        elif [[ "$have" == "absent" ]]; then
            continue
        elif [[ "$have" != "$want" ]]; then
            DG_HOLD_CRITICAL+=("$unit would restart -- $reason")
        fi
    done

    # critical processes
    local kind msg
    while IFS=$'\t' read -r kind msg; do
        case "$kind" in
            hold) DG_HOLD_PROCESS+=("$msg") ;;
            info) DG_INFO+=("$msg") ;;
        esac
    done < <(dg_classify_processes "$facts" "$probe")

    return 0
}

# The process half of dg_classify, separately so it is one awk program rather
# than a fork per process per declared package. Prints `hold\t<reason>` and
# `info\t<note>` lines.
#
# A declared process that is not running is not held: only the compositor in
# use matters, not the others that happen to be installed. But if any
# process could not be attributed (proc_unreadable > 0), "not running" cannot
# be told apart from "running and unreadable", so it is held as unknown.
dg_classify_processes() {
    local facts="$1" probe="$2" decl unreadable
    decl="$(jq -r '(.processes // {}) | to_entries[] | [.key, .value.pnames, .value.name, .value.path, .value.reason] | @tsv' <<<"$facts")"
    [[ -n "$decl" ]] || return 0
    unreadable="$(dg_probe_field "$probe" proc_unreadable)"

    {
        printf '%s\n' "$decl" | sed 's/^/D\t/'
        grep '^proc=' <<<"$probe" | sed 's/^proc=/P\t/' || true
    } | awk -F'\t' -v unreadable="${unreadable:-?}" "$DG_AWK_LIB"'
        $1 == "D" { n++; label[n] = $2; pnames[n] = " " $3 " "; tname[n] = $4; tpath[n] = $5; why[n] = $6; next }
        $1 == "P" { np++; run[np] = $2; next }
        END {
          for (i = 1; i <= n; i++) {
            parse_drv(tname[i]); tv = PV; tpn = PN
            found = 0
            for (j = 1; j <= np; j++) {
              rn = store_name(run[j]); parse_drv(rn)
              if (index(pnames[i], " " PN " ") == 0) continue
              found = 1
              if (PV != tv) {
                printf "hold\t%s running %s, target %s -- %s\n", label[i], rn, tname[i], why[i]
              } else if (run[j] != tpath[i] && PN == tpn) {
                printf "info\t%s %s rebuilt at the same version; not held\n", label[i], rn
              }
            }
            if (!found && unreadable != "0") {
              printf "hold\t%s: %s process(es) could not be attributed, so a running %s cannot be ruled out (run as root) -- %s\n", label[i], unreadable, label[i], why[i]
            }
          }
        }'
}

# ---------------------------------------------------------------------------
# Post-switch scan report (pure)
# ---------------------------------------------------------------------------
#
# dg_scan_report <scan-output-FILE>
#
# A file, not a string: the scan carries the whole closure (thousands of
# lines), and bash exports `$_` -- the last argument of the previous command
# -- into every child's environment. Pass a string that size as an argument
# and the next exec fails with "Argument list too long". Found by running it.
#
# Prints a human-readable report of processes running a binary that is not
# part of the new generation, and returns:
#
#   0  nothing stale
#   1  something stale (report printed)
#   2  the scan did not complete -- state UNKNOWN, not clean
#
# Split by owner, because the two need different advice:
#
#   system   uid < 1000. Activation restarts changed units, so anything left
#            is a unit it deliberately did not restart (NetworkManager's
#            reloadIfChanged, the display manager). Listed by unit, INCLUDING
#            same-version rebuilds: nixpkgs backports security patches
#            without a version bump, and a rebuilt NetworkManager is exactly
#            what the reloadIfChanged trade-off leaves unpatched.
#   session  uid >= 1000. Your open apps. Never restarted by activation.
#            Listed only when the VERSION moved; a same-version rebuild of
#            every open app after a mass rebuild is noise, so those are
#            counted.
#
# Only binaries from a PREVIOUS system generation count as stale. A binary in
# no generation at all (a `nix develop` shell, `nix run`, a dev build) was
# never installed, so it is counted as foreign, not listed.
dg_scan_report() {
    local file="$1" status
    status="$(awk 'index($0, "scan=") == 1 { print substr($0, 6); exit }' "$file")"
    if [[ "$status" != "done" ]]; then
        printf 'stale-process scan did not complete: %s\n' "${status:-no output}"
        printf '  Restart state is UNKNOWN, not clean.\n'
        return 2
    fi

    local report
    report="$(awk "$DG_AWK_LIB"'
        $1 == "closure" {
          inc[$2] = 1
          parse_drv(store_name($2))
          if (!((PN, PV) in seenv)) { seenv[PN, PV] = 1; vers[PN] = vers[PN] (vers[PN] == "" ? "" : ", ") PV }
          next
        }
        $1 == "old" { old[$2] = 1; next }
        $1 == "unreadable" { unread++; next }
        $1 == "proc" {
          pid = $2; uid = $3; unit = $4; sp = $5
          if (sp in inc) next
          rn = store_name(sp); parse_drv(rn); pn = PN; pv = PV
          if (!(sp in old)) { foreign[rn] = 1; next }
          if (uid != "-" && uid + 0 >= 1000) {
            if (index(", " vers[pn] ", ", ", " pv ", ") > 0) { rebuilt[rn] = 1; next }
            if (vers[pn] == "") { removed[rn] = 1; next }
            key = pn SUBSEP pv
            if (!(key in sess)) { sess[key] = 0; sorder[++ns] = key }
            sess[key]++
            next
          }
          key = unit SUBSEP rn
          if (!(key in sys)) { sys[key] = ""; yorder[++ny] = key }
          sys[key] = sys[key] (sys[key] == "" ? "" : " ") pid
        }
        END {
          for (i = 1; i <= ny; i++) {
            split(yorder[i], k, SUBSEP)
            rn = k[2]; parse_drv(rn)
            if (vers[PN] == "") to = "no longer in the new generation"
            else if (index(", " vers[PN] ", ", ", " PV ", ") > 0) to = "rebuilt, same version"
            else to = PN " " PV " -> " vers[PN]
            printf "system\t%s\t%s\t%s\t%s\n", k[1], sys[yorder[i]], rn, to
          }
          for (i = 1; i <= ns; i++) {
            split(sorder[i], k, SUBSEP)
            printf "session\t%s\t%s\t%s\t%d\n", k[1], k[2], vers[k[1]], sess[sorder[i]]
          }
          for (r in rebuilt) nr++
          for (r in foreign) nf++
          for (r in removed) printf "removed\t%s\n", r
          printf "counts\t%d\t%d\t%d\n", nr, nf, unread
        }' "$file")"

    local kind a b c d nsys=0 nsess=0 nrebuilt=0 nforeign=0 nunread=0 sys_lines="" sess_lines=""
    while IFS=$'\t' read -r kind a b c d; do
        case "$kind" in
            system)
                nsys=$((nsys + 1))
                sys_lines+="$(printf '    %-28s %s  (pid %s)\n      %s' "$a" "$c" "$b" "$d")"$'\n'
                ;;
            session)
                nsess=$((nsess + 1))
                sess_lines+="$(printf '    %-28s %s -> %s  (%s process(es))' "$a" "$b" "$c" "$d")"$'\n'
                ;;
            removed)
                nsess=$((nsess + 1))
                sess_lines+="$(printf '    %-28s no longer installed' "$a")"$'\n'
                ;;
            counts)
                nrebuilt="$a"
                nforeign="$b"
                nunread="$c"
                ;;
        esac
    done <<<"$report"

    if [[ "$nsys" -eq 0 && "$nsess" -eq 0 ]]; then
        if [[ "$nunread" -gt 0 ]]; then
            printf 'No stale processes found, but %s could not be read -- run as root for a complete answer.\n' "$nunread"
            return 2
        fi
        printf 'No stale processes: everything running is part of the new generation'
        [[ "$nrebuilt" -gt 0 ]] && printf ' (%s session app(s) rebuilt at the same version, not listed)' "$nrebuilt"
        printf '.\n'
        return 0
    fi

    if [[ "$nsys" -gt 0 ]]; then
        printf 'System services still running the previous binary (activation reloaded\n'
        printf 'rather than restarted them; a same-version rebuild can still be a\n'
        printf 'security fix):\n\n%s\n' "$sys_lines"
        printf '  Restart a unit with:  systemctl restart <unit>   (NetworkManager briefly drops the link)\n'
        printf '  or reboot.\n\n'
    fi
    if [[ "$nsess" -gt 0 ]]; then
        printf 'Open apps still running the version from before this switch:\n\n%s\n' "$sess_lines"
        printf '  Restart them to pick up the new version.\n\n'
    fi
    [[ "$nrebuilt" -gt 0 ]] && printf '  (%s session binary(ies) rebuilt at the same version, not listed.)\n' "$nrebuilt"
    [[ "$nforeign" -gt 0 ]] && printf '  (%s binary(ies) that were never part of any system generation -- dev shells, nix run -- not listed.)\n' "$nforeign"
    [[ "$nunread" -gt 0 ]] && printf '  WARNING: %s process(es) could not be read; run as root for a complete answer.\n' "$nunread"
    return 1
}
