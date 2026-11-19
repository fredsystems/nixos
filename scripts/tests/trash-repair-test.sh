#!/usr/bin/env bash
#
# trash-repair-test.sh -- hermetic tests for
# features/common/trash/repair-trashinfo.py, the ExecStartPre of the daily
# autotrash user service.
#
# Each case runs the real autotrash against a fixture trash directory, so
# "broken" means autotrash itself fails on it and "repaired" means autotrash
# itself then succeeds. A .trashinfo with no DeletionDate stopped autotrash
# on Daytona for five months (62 GB) without anything noticing.
#
# No network, no root, no Nix daemon: runs as a flake check
# (`.#checks.<system>.trash-repair`) and as a pre-commit hook.
#
# Usage: bash scripts/tests/trash-repair-test.sh   (from the repo root)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPAIR="$ROOT/features/common/trash/repair-trashinfo.py"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); }
bad() {
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n' "$1" >&2
    [[ $# -lt 2 ]] || printf '      %s\n' "${@:2}" >&2
}
eq() { # name expected actual
    if [[ "$2" == "$3" ]]; then ok; else bad "$1" "expected: $2" "actual:   $3"; fi
}
yes_() { # name cmd...
    local name="$1"
    shift
    if "$@" >/dev/null 2>&1; then ok; else bad "$name" "expected success: $*"; fi
}
no_() { # name cmd...
    local name="$1"
    shift
    if "$@" >/dev/null 2>&1; then bad "$name" "expected failure: $*"; else ok; fi
}

repair() { python3 "$REPAIR" "$@"; }
autotrash_run() { autotrash -q -d 10 -T "$1"; }

# new_trash NAME -> path of an empty, valid trash directory
new_trash() {
    local t="$WORK/$1"
    mkdir -p "$t/info" "$t/files"
    printf '%s\n' "$t"
}

# add_item TRASH NAME TRASHINFO_CONTENT [TOUCH_DATE]
add_item() {
    printf 'x\n' >"$1/files/$2"
    printf '%s' "$3" >"$1/info/$2.trashinfo"
    if [[ $# -ge 4 ]]; then
        touch -d "$4" "$1/info/$2.trashinfo"
    fi
}

OLD="$(date -d '30 days ago' +%Y-%m-%dT%H:%M:%S)"

# ---------------------------------------------------------------------------
# Missing info/ directory (every server that never trashed anything)
# ---------------------------------------------------------------------------

T="$WORK/never-used"
mkdir -p "$T"
no_ "no info dir: autotrash fails before repair" autotrash_run "$T"
yes_ "no info dir: repair succeeds" repair "$T"
yes_ "no info dir: info/ created" test -d "$T/info"
yes_ "no info dir: files/ created" test -d "$T/files"
yes_ "no info dir: autotrash succeeds after repair" autotrash_run "$T"

# ---------------------------------------------------------------------------
# No DeletionDate (the Daytona case), trashed long ago
# ---------------------------------------------------------------------------

T="$(new_trash no-date-old)"
add_item "$T" temp $'[Trash Info]\nPath=/home/fred/GitHub/frext/temp\n' "$OLD"
no_ "no date: autotrash fails before repair" autotrash_run "$T"

out="$(repair "$T")"
eq "no date: rewritten with the file timestamp" \
    $'[Trash Info]\nPath=/home/fred/GitHub/frext/temp\nDeletionDate='"$OLD" \
    "$(cat "$T/info/temp.trashinfo")"
case "$out" in
*"repaired temp.trashinfo: DeletionDate=$OLD"*) ok ;;
*) bad "no date: repair is logged" "output: $out" ;;
esac
eq "no date: timestamp preserved" "$OLD" \
    "$(date -r "$T/info/temp.trashinfo" +%Y-%m-%dT%H:%M:%S)"

yes_ "no date: autotrash succeeds after repair" autotrash_run "$T"
no_ "no date: 30-day-old item purged" test -e "$T/files/temp"
no_ "no date: its trashinfo purged" test -e "$T/info/temp.trashinfo"

# ---------------------------------------------------------------------------
# No DeletionDate, trashed just now: repaired but kept
# ---------------------------------------------------------------------------

T="$(new_trash no-date-new)"
add_item "$T" fresh $'[Trash Info]\nPath=/tmp/fresh\n'
repair "$T" >/dev/null
yes_ "recent: autotrash succeeds after repair" autotrash_run "$T"
yes_ "recent: item younger than --days is kept" test -e "$T/files/fresh"

# ---------------------------------------------------------------------------
# Other shapes autotrash cannot parse
# ---------------------------------------------------------------------------

T="$(new_trash unparsable)"
add_item "$T" no-header $'Path=/tmp/no-header\nDeletionDate=2026-01-01T00:00:00\n' "$OLD"
add_item "$T" bad-date $'[Trash Info]\nPath=/tmp/bad-date\nDeletionDate=yesterday\n' "$OLD"
add_item "$T" empty '' "$OLD"
add_item "$T" binary $'\xff\xfe\x00garbage' "$OLD"
no_ "unparsable: autotrash fails before repair" autotrash_run "$T"

out="$(repair "$T")"
case "$out" in
*"repaired 4 trashinfo file(s)"*) ok ;;
*) bad "unparsable: all four repaired" "output: $out" ;;
esac
eq "unparsable: missing header added, Path kept" \
    $'[Trash Info]\nPath=/tmp/no-header\nDeletionDate='"$OLD" \
    "$(cat "$T/info/no-header.trashinfo")"
eq "unparsable: bad date replaced" \
    $'[Trash Info]\nPath=/tmp/bad-date\nDeletionDate='"$OLD" \
    "$(cat "$T/info/bad-date.trashinfo")"
eq "unparsable: empty file gets a date" \
    $'[Trash Info]\nDeletionDate='"$OLD" \
    "$(cat "$T/info/empty.trashinfo")"
yes_ "unparsable: autotrash succeeds after repair" autotrash_run "$T"
eq "unparsable: every old item purged" "" "$(ls -A "$T/files")"

# ---------------------------------------------------------------------------
# Valid entries are never touched; reruns are no-ops
# ---------------------------------------------------------------------------

T="$(new_trash valid)"
GOOD=$'[Trash Info]\nPath=/tmp/a%20b\nDeletionDate=2026-11-19T10:08:16'
add_item "$T" good "$GOOD"
add_item "$T" fractional $'[Trash Info]\nPath=/tmp/f\nDeletionDate=2026-11-19T10:08:16.123456Z\n'
add_item "$T" broken $'[Trash Info]\nPath=/tmp/broken\n'
printf 'not a trashinfo\n' >"$T/info/README"
before="$(stat -c '%Y' "$T/info/good.trashinfo")"

out="$(repair "$T")"
case "$out" in
*"repaired 1 trashinfo file(s)"*) ok ;;
*) bad "valid: only the broken entry repaired" "output: $out" ;;
esac
eq "valid: content unchanged" "$GOOD" "$(cat "$T/info/good.trashinfo")"
eq "valid: mtime unchanged" "$before" "$(stat -c '%Y' "$T/info/good.trashinfo")"
eq "valid: non-trashinfo file ignored" "not a trashinfo" "$(cat "$T/info/README")"
eq "valid: no temp files left" "" "$(find "$T/info" -name '.repair-*')"
eq "rerun: prints nothing" "" "$(repair "$T")"

# ---------------------------------------------------------------------------
# Default directory follows XDG_DATA_HOME, like autotrash
# ---------------------------------------------------------------------------

mkdir -p "$WORK/xdg"
XDG_DATA_HOME="$WORK/xdg" repair >/dev/null
yes_ "xdg: default trash is \$XDG_DATA_HOME/Trash" test -d "$WORK/xdg/Trash/info"
no_ "usage: two arguments rejected" repair a b
pushd "$WORK" >/dev/null
no_ "usage: flag rejected" repair --help
popd >/dev/null
no_ "usage: flag did not create a directory" test -e "$WORK/--help"

# ---------------------------------------------------------------------------

printf 'trash-repair: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
