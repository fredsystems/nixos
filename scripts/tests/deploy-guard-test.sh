#!/usr/bin/env bash
#
# deploy-guard-test.sh -- hermetic tests for scripts/lib/deploy-guard.sh and
# the switch-preflight.sh verdict that is built on it.
#
# Every rule that decides between `switch` and `boot` is exercised here with
# fixtures, because the alternative is finding out on a frozen machine. The
# probe and scan scripts are run for real -- the same bytes that go over SSH
# -- against a fake /run, /nix/var and /proc tree (DEPLOY_GUARD_TEST_ROOT),
# with a stub nix-store on PATH.
#
# No network, no root, no Nix daemon: runs as a flake check
# (`.#checks.<system>.deploy-guard`) and as a pre-commit hook.
#
# Usage: bash scripts/tests/deploy-guard-test.sh   (from the repo root)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/deploy-guard.sh
source "$ROOT/scripts/lib/deploy-guard.sh"

PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ok() {
    PASS=$((PASS + 1))
}
bad() {
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n' "$1" >&2
    [[ $# -lt 2 ]] || printf '      %s\n' "${@:2}" >&2
}
eq() { # name expected actual
    if [[ "$2" == "$3" ]]; then ok; else bad "$1" "expected: $2" "actual:   $3"; fi
}
has() { # name needle haystack
    if [[ "$3" == *"$2"* ]]; then ok; else bad "$1" "missing: $2" "in:      ${3//$'\n'/ | }"; fi
}
lacks() { # name needle haystack
    if [[ "$3" != *"$2"* ]]; then ok; else bad "$1" "unexpected: $2" "in:         ${3//$'\n'/ | }"; fi
}

# 32-char store hashes, readable in failure output.
h() { printf '%-32s' "$1" | tr ' ' "${2:-0}"; }
sp() { printf '/nix/store/%s-%s' "$(h "$1")" "$2"; }

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

SYS_OLD="$(sp aaa nixos-system-box-26.11)"
SYS_NEW="$(sp bbb nixos-system-box-26.11)"
SD_OLD="$(sp sda systemd-261.3)"
SD_NEW="$(sp sdb systemd-262)"
SD_REBUILT="$(sp sdc systemd-261.3)"
K_OLD="$(sp ka linux-7.2.10)/bzImage"
K_NEW="$(sp kb linux-7.3)/bzImage"
M_OLD="$(sp ma linux-7.2.10-modules)"
M_NVIDIA="$(sp nv nvidia-x11-580.1-7.2.10)"
UNIT_OLD="$(sp ua unit-atticd.service)"
UNIT_NEW="$(sp ub unit-atticd.service)"
HYPR_RUN="$(sp hya hyprland-0.56.2)"
HYPR_REBUILT="$(sp hyb hyprland-0.56.2)"
HYPR_NEW="$(sp hyc hyprland-0.57.0)"

# facts <toplevel> <systemd> <kernel> <modules> [critical-json] [processes-json]
facts() {
    jq -cn --arg t "$1" --arg s "$2" --arg k "$3" --arg m "$4" \
        --argjson c "${5:-{\}}" --argjson p "${6:-{\}}" \
        '{toplevel: $t, systemd: $s, kernel: {image: $k, modules: $m}, critical: $c, processes: $p}'
}

# probe <toplevel> <systemd> <kernel> <modules> [extra lines...]
# A healthy node: booted == current, profile == current.
probe() {
    local t="$1" s="$2" k="$3" m="$4"
    shift 4
    printf '%s\n' "toplevel=$t" "booted=$t" "booted_systemd=$s" "systemd=$s" "profile=$t" \
        "kernel=$k" "modules=$m" "current_kernel=$k" "current_modules=$m" "$@"
}

HYPR_DECL="$(jq -cn --arg p "$HYPR_REBUILT" '{hyprland: {pnames: "hyprland", name: "hyprland-0.56.2", path: $p, reason: "compositor"}}')"
HYPR_DECL_NEW="$(jq -cn --arg p "$HYPR_NEW" '{hyprland: {pnames: "hyprland", name: "hyprland-0.57.0", path: $p, reason: "compositor"}}')"
ATTIC_DECL="$(jq -cn --arg p "$UNIT_NEW" '{"atticd.service": {reason: "the cache", path: $p}}')"

# ---------------------------------------------------------------------------
# parse_drv: must split exactly like builtins.parseDrvName
# ---------------------------------------------------------------------------
parse() { awk "$DG_AWK_LIB"'{ parse_drv($0); print PN "|" PV }' <<<"$1"; }
eq "parse plain" "hyprland|0.56.2" "$(parse hyprland-0.56.2)"
eq "parse multi-dash pname" "discord-unwrapped|1.0.161" "$(parse discord-unwrapped-1.0.161)"
eq "parse dotted pname" "python3.14-requests|2.32.5" "$(parse python3.14-requests-2.32.5)"
eq "parse output suffix kept in version" "dconf|0.49.0-lib" "$(parse dconf-0.49.0-lib)"
eq "parse no version" "unit-atticd.service|" "$(parse unit-atticd.service)"
eq "parse leading digit is pname" "0ad|0.27" "$(parse 0ad-0.27)"

eq "store_name strips hash and subpath" "linux-7.3" "$(dg_store_name "$K_NEW")"
eq "describe version change" "systemd-261.3 -> systemd-262" "$(dg_describe_change "$SD_OLD" "$SD_NEW")"
eq "describe rebuild" "systemd-261.3 (rebuilt, same version)" "$(dg_describe_change "$SD_OLD" "$SD_REBUILT")"

# ---------------------------------------------------------------------------
# dg_classify
# ---------------------------------------------------------------------------

# current: nothing to do, nothing held
dg_classify "$(facts "$SYS_OLD" "$SD_NEW" "$K_NEW" "$M_OLD")" "$(probe "$SYS_OLD" "$SD_OLD" "$K_OLD" "$M_OLD")"
eq "current state" current "$DG_STATE"
eq "current holds nothing" "" "$DG_HOLD_SYSTEMD$DG_HOLD_KERNEL"

# drifted, nothing relevant moved
dg_classify "$(facts "$SYS_NEW" "$SD_OLD" "$K_OLD" "$M_OLD")" "$(probe "$SYS_OLD" "$SD_OLD" "$K_OLD" "$M_OLD")"
eq "plain drift state" drifted "$DG_STATE"
eq "plain drift: no systemd hold" "" "$DG_HOLD_SYSTEMD"
eq "plain drift: no kernel hold" "" "$DG_HOLD_KERNEL"
eq "plain drift: nothing owed" "" "$DG_OWED"

# systemd: version bump, same-version rebuild, unreadable -- all hold
dg_classify "$(facts "$SYS_NEW" "$SD_NEW" "$K_OLD" "$M_OLD")" "$(probe "$SYS_OLD" "$SD_OLD" "$K_OLD" "$M_OLD")"
eq "systemd bump holds" "systemd systemd-261.3 -> systemd-262" "$DG_HOLD_SYSTEMD"
dg_classify "$(facts "$SYS_NEW" "$SD_REBUILT" "$K_OLD" "$M_OLD")" "$(probe "$SYS_OLD" "$SD_OLD" "$K_OLD" "$M_OLD")"
eq "systemd mass rebuild holds (PID 1 re-execs either way)" "systemd systemd-261.3 (rebuilt, same version)" "$DG_HOLD_SYSTEMD"
dg_classify "$(facts "$SYS_NEW" "$SD_OLD" "$K_OLD" "$M_OLD")" "$(probe "$SYS_OLD" "" "$K_OLD" "$M_OLD")"
eq "unreadable systemd holds" "running systemd unreadable, treated as changed" "$DG_HOLD_SYSTEMD"

# kernel: against the BOOTED kernel
dg_classify "$(facts "$SYS_NEW" "$SD_OLD" "$K_NEW" "$M_OLD")" "$(probe "$SYS_OLD" "$SD_OLD" "$K_OLD" "$M_OLD")"
eq "kernel bump holds" "kernel linux-7.2.10 -> linux-7.3" "$DG_HOLD_KERNEL"
dg_classify "$(facts "$SYS_NEW" "$SD_OLD" "$K_OLD" "$M_OLD $M_NVIDIA")" "$(probe "$SYS_OLD" "$SD_OLD" "$K_OLD" "$M_OLD")"
eq "new out-of-tree module holds" "kernel modules change: nvidia-x11-580.1-7.2.10" "$DG_HOLD_KERNEL"
dg_classify "$(facts "$SYS_NEW" "$SD_OLD" "$K_OLD" "$M_OLD")" "$(probe "$SYS_OLD" "$SD_OLD" "$K_OLD" "")"
eq "unreadable modules hold" "booted kernel unreadable, treated as changed" "$DG_HOLD_KERNEL"

# a kernel already switched into live: target == current-system's, still held
# because the node never BOOTED it, and the reboot is reported as owed
p="$(probe "$SYS_OLD" "$SD_OLD" "$K_OLD" "$M_OLD" | sed "s|^current_kernel=.*|current_kernel=$K_NEW|")"
dg_classify "$(facts "$SYS_NEW" "$SD_OLD" "$K_NEW" "$M_OLD")" "$p"
eq "kernel switched live: held vs booted" "kernel linux-7.2.10 -> linux-7.3" "$DG_HOLD_KERNEL"
eq "kernel switched live: reboot owed" "kernel" "$DG_OWED"

# staged generation owed, even when the node is otherwise current
p="$(probe "$SYS_OLD" "$SD_OLD" "$K_OLD" "$M_OLD" | sed "s|^profile=.*|profile=$SYS_NEW|")"
dg_classify "$(facts "$SYS_OLD" "$SD_OLD" "$K_OLD" "$M_OLD")" "$p"
eq "staged: state current" current "$DG_STATE"
eq "staged: reboot owed" "staged generation" "$DG_OWED"

# systemd switched into live (old --allow-unsafe-switch): owed
p="$(probe "$SYS_OLD" "$SD_OLD" "$K_OLD" "$M_OLD" | sed "s|^booted_systemd=.*|booted_systemd=$SD_REBUILT|")"
dg_classify "$(facts "$SYS_OLD" "$SD_OLD" "$K_OLD" "$M_OLD")" "$p"
eq "systemd switched live: owed" "systemd systemd-261.3 (rebuilt, same version)" "$DG_OWED"

# empty probe
dg_classify "$(facts "$SYS_NEW" "$SD_OLD" "$K_OLD" "$M_OLD")" ""
eq "empty probe is noprobe, not drift" noprobe "$DG_STATE"

# critical units
f="$(facts "$SYS_NEW" "$SD_OLD" "$K_OLD" "$M_OLD" "$ATTIC_DECL")"
dg_classify "$f" "$(probe "$SYS_OLD" "$SD_OLD" "$K_OLD" "$M_OLD" "unit:atticd.service=$UNIT_OLD")"
eq "critical unit change holds" "atticd.service would restart -- the cache" "${DG_HOLD_CRITICAL[*]}"
dg_classify "$f" "$(probe "$SYS_OLD" "$SD_OLD" "$K_OLD" "$M_OLD" "unit:atticd.service=$UNIT_NEW")"
eq "critical unit unchanged" 0 "${#DG_HOLD_CRITICAL[@]}"
dg_classify "$f" "$(probe "$SYS_OLD" "$SD_OLD" "$K_OLD" "$M_OLD" "unit:atticd.service=absent")"
eq "critical unit absent: started, not restarted" "0 0" "${#DG_HOLD_CRITICAL[@]} ${#DG_CRITICAL_UNKNOWN[@]}"
dg_classify "$f" "$(probe "$SYS_OLD" "$SD_OLD" "$K_OLD" "$M_OLD" "unit:atticd.service=?")"
eq "critical unit unreadable: reported, not held" "0 1" "${#DG_HOLD_CRITICAL[@]} ${#DG_CRITICAL_UNKNOWN[@]}"

# critical processes
pf() { facts "$SYS_NEW" "$SD_OLD" "$K_OLD" "$M_OLD" "{}" "$1"; }
base() { probe "$SYS_OLD" "$SD_OLD" "$K_OLD" "$M_OLD" "$@"; }

dg_classify "$(pf "$HYPR_DECL_NEW")" "$(base "proc=$HYPR_RUN" "proc_unreadable=0")"
eq "running compositor version bump holds" \
    "hyprland running hyprland-0.56.2, target hyprland-0.57.0 -- compositor" "${DG_HOLD_PROCESS[*]}"

dg_classify "$(pf "$HYPR_DECL")" "$(base "proc=$HYPR_RUN" "proc_unreadable=0")"
eq "compositor same-version rebuild: not held" 0 "${#DG_HOLD_PROCESS[@]}"
has "compositor same-version rebuild: noted" "rebuilt at the same version" "${DG_INFO[*]}"

dg_classify "$(pf "$HYPR_DECL_NEW")" "$(base "proc=$(sp zz zsh-5.9.2)" "proc_unreadable=0")"
eq "installed-but-not-running compositor: not held" 0 "${#DG_HOLD_PROCESS[@]}"

dg_classify "$(pf "$HYPR_DECL_NEW")" "$(base "proc_unreadable=3")"
has "not found but processes unreadable: held as unknown" "could not be attributed" "${DG_HOLD_PROCESS[*]}"

dg_classify "$(pf "$HYPR_DECL_NEW")" "$(base "proc=$(sp hp hyprland-protocols-0.7.0)" "proc_unreadable=0")"
eq "pname match is exact (hyprland-protocols is not hyprland)" 0 "${#DG_HOLD_PROCESS[@]}"

disc="$(jq -cn --arg p "$(sp dc discord-1.0.170)" '{discord: {pnames: "discord discord-unwrapped", name: "discord-1.0.170", path: $p, reason: "r"}}')"
dg_classify "$(pf "$disc")" "$(base "proc=$(sp du discord-unwrapped-1.0.161)" "proc_unreadable=0")"
has "alternate pname (unwrapped) is matched" "discord-unwrapped-1.0.161, target discord-1.0.170" "${DG_HOLD_PROCESS[*]}"

# name validation
eq "unit names validated" "bad;name.service" "$(dg_bad_names "$DG_UNIT_NAME_RE" ok.service 'bad;name.service' getty@tty1.service)"
# shellcheck disable=SC2016 # a literal command substitution is the payload under test
evil='rm$(x)'
eq "pnames validated" "$evil" "$(dg_bad_names "$DG_PNAME_RE" hyprland "$evil" gnome-shell python3.14)"
if dg_validate_facts "$(pf "$(jq -cn '{x: {pnames: "a b;c", name: "a-1", path: "/p", reason: "r"}}')")" >/dev/null; then
    bad "dg_validate_facts must reject an unsafe pname"
else
    ok
fi

# ---------------------------------------------------------------------------
# The probe script, run for real against a fixture tree
# ---------------------------------------------------------------------------
R="$WORK/root"
STORE="$WORK/store"
mkdir -p "$R/run" "$R/nix/var/nix/profiles" "$R/proc"

mk_system() { # <dir> <systemd> <kernel-dir> <modules-tree>
    mkdir -p "$1/etc/systemd/system" "$2" "$3"
    ln -s "$2" "$1/systemd"
    ln -s "$3" "$1/kernel"
    ln -s "$4" "$1/kernel-modules"
}
mkdir -p "$STORE/unit-atticd.service" "$STORE/modtree"
touch "$STORE/unit-atticd.service/atticd.service"
mk_system "$STORE/sys" "$STORE/systemd-261.3" "$STORE/linux-7.2.10" "$STORE/modtree"
ln -s "$STORE/unit-atticd.service/atticd.service" "$STORE/sys/etc/systemd/system/atticd.service"
ln -s "$STORE/sys" "$R/run/current-system"
ln -s "$STORE/sys" "$R/run/booted-system"
ln -s "$STORE/sys" "$R/nix/var/nix/profiles/system"
ln -s "$STORE/sys" "$R/nix/var/nix/profiles/system-41-link"

# Stub nix-store, as a shell function prepended to the script under test
# rather than an executable on PATH: a stub executable would need a shebang,
# and the Nix build sandbox this runs in has /bin/sh but no /usr/bin/env.
STUB="$(cat <<EOF
nix-store() {
  case "\$*" in
    "-q --references $STORE/modtree") printf '%s\n' "$M_NVIDIA" "$M_OLD" ;;
    "-q --requisites $STORE/sys") cat "$WORK/closure-new" ;;
    "-q --requisites $R/nix/var/nix/profiles/system-41-link $R/run/booted-system") cat "$WORK/closure-old" ;;
    *) return 1 ;;
  esac
}
EOF
)"

# Run a guard script against the fixture tree, exactly as a node would.
run_fixture() {
    DEPLOY_GUARD_TEST_ROOT="$R" /bin/sh -s <<<"$STUB
$1"
}

# Fake processes. exe present => authoritative; exe absent => argv[0]
# fallback; empty cmdline => kernel thread.
mkproc() { # <pid> <uid> <unit> <exe-or-empty> <argv0>
    local d="$R/proc/$1"
    mkdir -p "$d"
    printf 'Name:\tx\nUid:\t%s\t%s\t%s\t%s\n' "$2" "$2" "$2" "$2" >"$d/status"
    printf '0::/some.slice/%s\n' "$3" >"$d/cgroup"
    [[ -z "$4" ]] || ln -s "$4" "$d/exe"
    printf '%s\0--flag\0' "$5" >"$d/cmdline"
}
NM_OLD="$(sp nma networkmanager-1.58.1)"
NM_NEW="$(sp nmb networkmanager-1.58.1)"
BRAVE_OLD="$(sp bra brave-1.97.57)"
BRAVE_NEW="$(sp brb brave-1.98.10)"
ZSH="$(sp zs zsh-5.9.2)"
DEVBASH="$(sp db bash-5.3p20)"
mkproc 100 0 NetworkManager.service "$NM_OLD/bin/NetworkManager" "$NM_OLD/bin/NetworkManager"
mkproc 200 1000 app-hyprland.scope "" "$HYPR_RUN/bin/Hyprland"
mkproc 300 1000 app-brave.scope "$BRAVE_OLD/opt/brave/brave" "brave"
mkproc 301 1000 app-brave.scope "$BRAVE_OLD/opt/brave/brave" "brave"
mkproc 400 1000 zsh.scope "$ZSH/bin/zsh" "-zsh"
mkproc 500 1000 dev.scope "$DEVBASH/bin/bash" "bash"
mkproc 600 0 init.scope "" "systemd"
mkdir -p "$R/proc/2"
: >"$R/proc/2/cmdline"

printf '%s\n' "$NM_NEW" "$BRAVE_NEW" "$ZSH" "$(sp bash5 bash-5.3p15)" >"$WORK/closure-new"
printf '%s\n' "$NM_OLD" "$BRAVE_OLD" "$ZSH" "$HYPR_RUN" >"$WORK/closure-old"

out="$(run_fixture "$(dg_probe_script "atticd.service missing.service" 1)")"
eq "probe toplevel" "$STORE/sys" "$(dg_probe_field "$out" toplevel)"
eq "probe systemd" "$STORE/systemd-261.3" "$(dg_probe_field "$out" systemd)"
eq "probe profile" "$STORE/sys" "$(dg_probe_field "$out" profile)"
eq "probe kernel" "$STORE/linux-7.2.10" "$(dg_probe_field "$out" kernel)"
eq "probe modules sorted by byte order" "$(printf '%s\n' "$M_NVIDIA" "$M_OLD" | LC_ALL=C sort | paste -sd ' ' -)" "$(dg_probe_field "$out" modules)"
eq "probe unit is the unit derivation, not the file" "$STORE/unit-atticd.service" "$(dg_probe_field "$out" unit:atticd.service)"
eq "probe absent unit" "absent" "$(dg_probe_field "$out" unit:missing.service)"
has "probe attributes by exe" "proc=$BRAVE_OLD" "$out"
has "probe falls back to a store argv0 when exe is unreadable" "proc=$HYPR_RUN" "$out"
eq "probe dedupes store prefixes" 1 "$(grep -c "^proc=$BRAVE_OLD\$" <<<"$out")"
eq "probe counts unattributable processes (pid 600), skips kernel threads" 1 "$(dg_probe_field "$out" proc_unreadable)"

out="$(run_fixture "$(dg_probe_script "" 0)")"
lacks "probe skips /proc when no critical process is declared" "proc" "$(grep -E '^proc' <<<"$out" || true)"

# End to end: the probed block, classified.
dg_classify "$(pf "$HYPR_DECL_NEW")" "$(run_fixture "$(dg_probe_script "" 1)")"
has "probe -> classify: running compositor bump held" "hyprland running hyprland-0.56.2, target hyprland-0.57.0" "${DG_HOLD_PROCESS[*]}"

# ---------------------------------------------------------------------------
# The post-switch scan
# ---------------------------------------------------------------------------
run_fixture "$(dg_scan_script)" >"$WORK/scan"
set +e
report="$(dg_scan_report "$WORK/scan")"
rc=$?
set -e
eq "scan: stale found returns 1" 1 "$rc"
has "scan: rebuilt system daemon listed by unit" "NetworkManager.service" "$report"
has "scan: system rebuild described" "rebuilt, same version" "$report"
has "scan: session app version change listed" "brave" "$report"
has "scan: session versions" "1.97.57 -> 1.98.10" "$report"
has "scan: process count" "(2 process(es))" "$report"
has "scan: removed session app listed" "hyprland-0.56.2" "$report"
lacks "scan: in-closure process not listed" "zsh" "$report"
lacks "scan: dev-shell binary (in no generation) not listed" "5.3p20" "$report"
has "scan: dev-shell binary counted as foreign" "never part of any system generation" "$report"
has "scan: unreadable reported" "could not be read" "$report"

printf 'closure %s\nscan=done\n' "$ZSH" >"$WORK/scan-clean"
set +e
report="$(dg_scan_report "$WORK/scan-clean")"
rc=$?
set -e
eq "scan: clean returns 0" 0 "$rc"

printf 'closure %s\nproc 1 0 x %s\n' "$ZSH" "$NM_OLD" >"$WORK/scan-cut"
set +e
report="$(dg_scan_report "$WORK/scan-cut")"
rc=$?
set -e
eq "scan: no scan=done is incomplete, never clean" 2 "$rc"
: >"$WORK/scan-empty"
set +e
dg_scan_report "$WORK/scan-empty" >/dev/null
rc=$?
set -e
eq "scan: empty output (ssh never ran) is incomplete" 2 "$rc"

# ---------------------------------------------------------------------------
# switch-preflight.sh verdicts (fixture mode)
# ---------------------------------------------------------------------------
preflight() {
    set +e
    PREFLIGHT_OUT="$(bash "$ROOT/scripts/switch-preflight.sh" --facts-file "$WORK/f.json" --probe-file "$WORK/p.txt" "$@" 2>&1)"
    PREFLIGHT_RC=$?
    set -e
}

facts "$SYS_NEW" "$SD_OLD" "$K_OLD" "$M_OLD" >"$WORK/f.json"
probe "$SYS_OLD" "$SD_OLD" "$K_OLD" "$M_OLD" >"$WORK/p.txt"
preflight
eq "preflight: nothing moved -> switch (0)" 0 "$PREFLIGHT_RC"
has "preflight: says safe" "VERDICT: safe to switch." "$PREFLIGHT_OUT"

facts "$SYS_NEW" "$SD_NEW" "$K_NEW" "$M_OLD" >"$WORK/f.json"
preflight
eq "preflight: systemd + kernel -> boot (10)" 10 "$PREFLIGHT_RC"
has "preflight: names systemd" "HOLD      systemd systemd-261.3 -> systemd-262" "$PREFLIGHT_OUT"
has "preflight: names kernel" "HOLD      kernel linux-7.2.10 -> linux-7.3" "$PREFLIGHT_OUT"

preflight --allow-unsafe-switch
eq "preflight: one override is not enough" 10 "$PREFLIGHT_RC"
preflight --allow-unsafe-switch --allow-kernel-switch
eq "preflight: both overridden -> 0" 0 "$PREFLIGHT_RC"
has "preflight: override still reported" "ALLOWED   systemd" "$PREFLIGHT_OUT"

facts "$SYS_NEW" "$SD_OLD" "$K_OLD" "$M_OLD" "{}" "$HYPR_DECL_NEW" >"$WORK/f.json"
probe "$SYS_OLD" "$SD_OLD" "$K_OLD" "$M_OLD" "proc=$HYPR_RUN" "proc_unreadable=0" >"$WORK/p.txt"
preflight
eq "preflight: compositor bump -> 10" 10 "$PREFLIGHT_RC"
preflight --allow-process-change
eq "preflight: compositor override -> 0" 0 "$PREFLIGHT_RC"

: >"$WORK/p.txt"
preflight
eq "preflight: unreadable system is an error, not a verdict" 1 "$PREFLIGHT_RC"

set +e
bash "$ROOT/scripts/switch-preflight.sh" --facts-file "$WORK/f.json" >/dev/null 2>&1
rc=$?
set -e
eq "preflight: --facts-file without --probe-file is an error" 1 "$rc"

# ---------------------------------------------------------------------------
printf 'deploy-guard: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
