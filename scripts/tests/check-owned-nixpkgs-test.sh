#!/usr/bin/env bash
#
# check-owned-nixpkgs-test.sh -- hermetic tests for
# scripts/check-owned-nixpkgs.sh, the check that every root flake input
# keeping its own nixpkgs documents why in flake.nix.
#
# Each fixture pair under scripts/tests/fixtures/owned-nixpkgs/<case>/
# holds a minimal flake.lock + flake.nix exercising one case. The script
# under test is run for real against each pair, exactly as it would be
# run against the repo root.
#
# Also runs the script against the real flake.lock / flake.nix, so a
# future owned-nixpkgs input added without a reason fails here rather
# than only in CI.
#
# No network, no root, no Nix daemon: runs as a flake check
# (`.#checks.<system>.owned-nixpkgs`) and as a pre-commit hook.
#
# Usage: bash scripts/tests/check-owned-nixpkgs-test.sh   (from the repo root)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/check-owned-nixpkgs.sh"
FIXTURES="$ROOT/scripts/tests/fixtures/owned-nixpkgs"

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
has() { # name needle haystack
    if [[ "$3" == *"$2"* ]]; then ok; else bad "$1" "missing: $2" "in:      ${3//$'\n'/ | }"; fi
}

# run <case> -- invokes the script against a fixture pair, capturing its
# exit code and combined output.
run() {
    local case="$1"
    set +e
    OUT="$(bash "$SCRIPT" "$FIXTURES/$case/flake.lock" "$FIXTURES/$case/flake.nix" 2>&1)"
    RC=$?
    set -e
}

# ---------------------------------------------------------------------------
# (a) an input that follows nixpkgs needs no NOTE -> pass
# ---------------------------------------------------------------------------

run follows
eq "follows: exit 0" 0 "$RC"
has "follows: reports nothing owned" "all 0 inputs" "$OUT"

# ---------------------------------------------------------------------------
# (b) an owning input with a NOTE directly above -> pass
# ---------------------------------------------------------------------------

run note
eq "note: exit 0" 0 "$RC"
has "note: reports one input" "all 1 inputs" "$OUT"

# ---------------------------------------------------------------------------
# (c) an owning input with no comment at all -> fail, names it
# ---------------------------------------------------------------------------

run no-comment
eq "no-comment: exit 1" 1 "$RC"
has "no-comment: names colmena" "colmena: owns its nixpkgs" "$OUT"

# ---------------------------------------------------------------------------
# (d) an owning input whose NOTE is separated from the attr by a blank
# line -> fail, names it
# ---------------------------------------------------------------------------

run blank-line
eq "blank-line: exit 1" 1 "$RC"
has "blank-line: names catppuccin" "catppuccin: owns its nixpkgs" "$OUT"

run empty-note
eq "empty-note: exit 1" 1 "$RC"
has "empty-note: names catppuccin" "catppuccin: owns its nixpkgs" "$OUT"

run empty-note-renovate
eq "empty-note-renovate: exit 1" 1 "$RC"
has "empty-note-renovate: names catppuccin" "catppuccin: owns its nixpkgs" "$OUT"

run note-continued
eq "note-continued: exit 0" 0 "$RC"

# ---------------------------------------------------------------------------
# (e) an owning input whose comment run has a `# renovate:` line after the
# NOTE line (like opencode in the real flake.nix) -> pass
# ---------------------------------------------------------------------------

run renovate-after-note
eq "renovate-after-note: exit 0" 0 "$RC"
has "renovate-after-note: reports one input" "all 1 inputs" "$OUT"

# ---------------------------------------------------------------------------
# (f) the real repo flake.lock + flake.nix -> pass
# ---------------------------------------------------------------------------

set +e
REAL_OUT="$(bash "$SCRIPT" "$ROOT/flake.lock" "$ROOT/flake.nix" 2>&1)"
REAL_RC=$?
set -e
eq "real repo: exit 0" 0 "$REAL_RC"
if [[ "$REAL_RC" -ne 0 ]]; then
    printf '      %s\n' "${REAL_OUT//$'\n'/ | }" >&2
fi

# ---------------------------------------------------------------------------

printf 'check-owned-nixpkgs: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
