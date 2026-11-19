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
# The vanishing-entry case imports the script; keep __pycache__ out of the tree.
export PYTHONDONTWRITEBYTECODE=1

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
# Path handling: kept whenever configparser could have read it
# ---------------------------------------------------------------------------

T="$(new_trash paths)"
add_item "$T" spaced $'[Trash Info]\nPath = /tmp/keep me \n' "$OLD"
add_item "$T" colon $'[Trash Info]\npath: /tmp/colon\n' "$OLD"
add_item "$T" escaped $'[Trash Info]\nPath=/tmp/a%20b\n' "$OLD"
add_item "$T" unicode $'[Trash Info]\nPath=/tmp/\xc3\xa9t\xc3\xa9\n' "$OLD"
add_item "$T" invalid $'[Trash Info]\nPath=/tmp/bad\xff\xfe\n' "$OLD"
add_item "$T" carriage $'[Trash Info]\nPath=/tmp/a\rjunk\n' "$OLD"
# Only [Trash Info]'s Path counts: restoring to another section's Path
# would put the item in the wrong place.
add_item "$T" sections $'[Other]\nPath=/tmp/wrong\n[Trash Info]\nPath=/tmp/right\n' "$OLD"
add_item "$T" sections-broken $'[Other]\nPath=/tmp/wrong\n[Trash Info]\nPath=/tmp/right\njunk\n[Later]\nPath=/tmp/later\n' "$OLD"
add_item "$T" other-only $'[Other]\nPath=/tmp/wrong\n' "$OLD"
add_item "$T" headerless-then-other $'Path=/tmp/right\n[Other]\nPath=/tmp/wrong\n' "$OLD"
no_ "paths: autotrash fails before repair" autotrash_run "$T"

out="$(repair "$T")"
eq "paths: whitespace around = is not a lost Path" \
    $'[Trash Info]\nPath=/tmp/keep me\nDeletionDate='"$OLD" \
    "$(cat "$T/info/spaced.trashinfo")"
eq "paths: ':' delimiter and key case accepted" \
    $'[Trash Info]\nPath=/tmp/colon\nDeletionDate='"$OLD" \
    "$(cat "$T/info/colon.trashinfo")"
eq "paths: existing escapes unchanged" \
    $'[Trash Info]\nPath=/tmp/a%20b\nDeletionDate='"$OLD" \
    "$(cat "$T/info/escaped.trashinfo")"
eq "paths: valid UTF-8 unchanged" \
    $'[Trash Info]\nPath=/tmp/\xc3\xa9t\xc3\xa9\nDeletionDate='"$OLD" \
    "$(cat "$T/info/unicode.trashinfo")"
eq "paths: invalid UTF-8 percent-encoded" \
    $'[Trash Info]\nPath=/tmp/bad%FF%FE\nDeletionDate='"$OLD" \
    "$(cat "$T/info/invalid.trashinfo")"
eq "paths: Path dropped when it still breaks parsing" \
    $'[Trash Info]\nDeletionDate='"$OLD" \
    "$(cat "$T/info/carriage.trashinfo")"
eq "sections: [Trash Info] Path wins over an earlier section" \
    $'[Trash Info]\nPath=/tmp/right\nDeletionDate='"$OLD" \
    "$(cat "$T/info/sections.trashinfo")"
eq "sections: same when the file does not parse" \
    $'[Trash Info]\nPath=/tmp/right\nDeletionDate='"$OLD" \
    "$(cat "$T/info/sections-broken.trashinfo")"
eq "sections: another section's Path is never used" \
    $'[Trash Info]\nDeletionDate='"$OLD" \
    "$(cat "$T/info/other-only.trashinfo")"
eq "sections: headerless Path before another section is kept" \
    $'[Trash Info]\nPath=/tmp/right\nDeletionDate='"$OLD" \
    "$(cat "$T/info/headerless-then-other.trashinfo")"
case "$out" in
*"carriage.trashinfo: DeletionDate=$OLD (from file timestamp; Path dropped"*) ok ;;
*) bad "paths: dropped Path is logged" "output: $out" ;;
esac
yes_ "paths: autotrash succeeds after repair" autotrash_run "$T"
eq "paths: every old item purged" "" "$(ls -A "$T/files")"

# ---------------------------------------------------------------------------
# An entry restored or emptied mid-run is skipped, not fatal
# ---------------------------------------------------------------------------

T="$(new_trash vanishing)"
add_item "$T" gone $'[Trash Info]\nPath=/tmp/gone\n' "$OLD"
add_item "$T" stays $'[Trash Info]\nPath=/tmp/stays\n' "$OLD"
# Deterministic race: the entry disappears right after the isfile() check.
vanish() {
    python3 - "$REPAIR" "$1" <<'PY'
import importlib.util
import os
import sys

spec = importlib.util.spec_from_file_location("repair", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

real_isfile = os.path.isfile


def isfile(path):
    present = real_isfile(path)
    if path.endswith("gone.trashinfo"):
        os.unlink(path)
    return present


mod.os.path.isfile = isfile
sys.exit(mod.main(["autotrash-repair", sys.argv[2]]))
PY
}
yes_ "vanishing: repair still succeeds" vanish "$T"
eq "vanishing: the rest is still repaired" \
    $'[Trash Info]\nPath=/tmp/stays\nDeletionDate='"$OLD" \
    "$(cat "$T/info/stays.trashinfo")"
no_ "vanishing: nothing recreated" test -e "$T/info/gone.trashinfo"

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
