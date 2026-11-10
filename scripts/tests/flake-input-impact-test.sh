#!/usr/bin/env bash
#
# flake-input-impact-test.sh -- hermetic tests for
# scripts/flake-input-impact.sh.
#
# Builds small fixture flakes (scripts/tests/fixtures/flake-input-impact/)
# in a scratch git+file:// tree so the whole thing runs fully offline and
# fast: no nixpkgs is evaluated (every output is a `builtins.derivation`
# whose attrs are only ever hashed, never built), and every input is a
# local path, so "nix flake update/lock" touches nothing outside the
# temp dir.
#
# Usage: bash scripts/tests/flake-input-impact-test.sh   (from the repo root)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/flake-input-impact.sh"
FIXTURES="$ROOT/scripts/tests/fixtures/flake-input-impact"

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); }
bad() {
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n' "$1" >&2
    [[ $# -lt 2 ]] || printf '      %s\n' "${@:2}" >&2
}

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# See the matching comment in scripts/flake-input-impact.sh: the
# pre-commit-hook / flake-check sandbox starts from a clean nix.conf.
NIX_FEATURES=(--extra-experimental-features "nix-command flakes")

git_init_commit() { # dir message
    (
        cd "$1"
        git init -q
        git add -A
        git -c user.email=test@example.com -c user.name=test commit -q -m "$2"
    )
}

git_commit_all() { # dir message
    (
        cd "$1"
        git add -A
        git -c user.email=test@example.com -c user.name=test commit -q -m "$2"
    )
}

copy_fixture() { # name
    local name="$1"
    cp -R "$FIXTURES/$name" "$TMPROOT/$name"
    # @TMPROOT@ is the only placeholder the fixtures use, standing in for
    # this run's scratch directory (unknown until mktemp runs above).
    sed -i "s#@TMPROOT@#$TMPROOT#g" "$TMPROOT/$name/flake.nix"
}

# ---------------------------------------------------------------------------
# Build the fixture tree.
# ---------------------------------------------------------------------------

copy_fixture "fake-nixpkgs"
git_init_commit "$TMPROOT/fake-nixpkgs" "init"

copy_fixture "dep-follow"
git_init_commit "$TMPROOT/dep-follow" "init"

copy_fixture "dep-source"
git_init_commit "$TMPROOT/dep-source" "init"

# dep-owning's nixpkgs is a local tarball, not a flake input repo: real
# channel-tarball inputs (catppuccin/nixpkgs) are immutable per-URL
# snapshots, so each "version" here is its own tarball rather than one
# tarball overwritten in place -- overwriting it would make the OLD url
# unfetchable, breaking the override test for case (c) below.
mkdir -p "$TMPROOT/tarballs"
cp -R "$FIXTURES/nixpkgs-owned" "$TMPROOT/nixpkgs-owned-src-v1"
tar -C "$TMPROOT/nixpkgs-owned-src-v1" -czf "$TMPROOT/tarballs/nixpkgs-owned-v1.tar.gz" flake.nix

copy_fixture "dep-owning"
git_init_commit "$TMPROOT/dep-owning" "init"
(cd "$TMPROOT/dep-owning" && nix "${NIX_FEATURES[@]}" flake lock --impure >/dev/null 2>&1)
git_commit_all "$TMPROOT/dep-owning" "lock"

copy_fixture "consumer"
git_init_commit "$TMPROOT/consumer" "init"
(cd "$TMPROOT/consumer" && nix "${NIX_FEATURES[@]}" flake lock --impure >/dev/null 2>&1)
git_commit_all "$TMPROOT/consumer" "lock"

run_script() { # input [extra args...]
    local input="$1"
    shift
    bash "$SCRIPT" --flake "$TMPROOT/consumer" "$@" "$input" 2>"$TMPROOT/stderr.log"
}

expect_kind() { # name input expected_kind
    local name="$1" input="$2" expected="$3"
    local actual
    if actual="$(run_script "$input")"; then
        if [[ "$actual" == "$expected" ]]; then
            ok
        else
            bad "$name" "expected: $expected" "actual: $actual" "stderr:" "$(cat "$TMPROOT/stderr.log")"
        fi
    else
        bad "$name" "script failed (expected kind $expected)" "stderr:" "$(cat "$TMPROOT/stderr.log")"
    fi
}

# ---------------------------------------------------------------------------
# (a) upstream not moved -> none
# ---------------------------------------------------------------------------

expect_kind "(a) upstream not moved" "dep-source" "none"

# ---------------------------------------------------------------------------
# (b) an input that follows the root's nixpkgs moves, but nothing in the
#     outputs uses its changed part -> none
# ---------------------------------------------------------------------------

sed -i 's/follow-v1/follow-v2/' "$TMPROOT/dep-follow/flake.nix"
git_commit_all "$TMPROOT/dep-follow" "bump marker (unused)"

expect_kind "(b) moved but unused" "dep-follow" "none"

# ---------------------------------------------------------------------------
# (c) an input that owns its nixpkgs moves ONLY its nested nixpkgs (its own
#     source unchanged) and its outputs depend on that nixpkgs -> rebuild
# ---------------------------------------------------------------------------

cp -R "$FIXTURES/nixpkgs-owned" "$TMPROOT/nixpkgs-owned-src-v2"
sed -i 's/owned-tar-v1/owned-tar-v2/' "$TMPROOT/nixpkgs-owned-src-v2/flake.nix"
tar -C "$TMPROOT/nixpkgs-owned-src-v2" -czf "$TMPROOT/tarballs/nixpkgs-owned-v2.tar.gz" flake.nix

sed -i 's#nixpkgs-owned-v1\.tar\.gz#nixpkgs-owned-v2.tar.gz#' "$TMPROOT/dep-owning/flake.nix"
(cd "$TMPROOT/dep-owning" && nix "${NIX_FEATURES[@]}" flake lock --impure >/dev/null 2>&1)
git_commit_all "$TMPROOT/dep-owning" "bump own nixpkgs pointer to v2"

expect_kind "(c) owned nixpkgs moves alone" "dep-owning" "rebuild"

# ---------------------------------------------------------------------------
# (d) an input whose own source changes in a way an output uses -> source
# ---------------------------------------------------------------------------

sed -i 's/src-v1/src-v2/' "$TMPROOT/dep-source/flake.nix"
git_commit_all "$TMPROOT/dep-source" "bump value"

expect_kind "(d) own source change, used" "dep-source" "source"

# ---------------------------------------------------------------------------
# (e) unknown input -> exit 2
# ---------------------------------------------------------------------------

if run_script "no-such-input" >/dev/null 2>"$TMPROOT/stderr.log"; then
    bad "(e) unknown input" "expected a non-zero exit" "stderr:" "$(cat "$TMPROOT/stderr.log")"
else
    rc=$?
    if [[ $rc -eq 2 ]]; then
        ok
    else
        bad "(e) unknown input" "expected exit 2" "actual exit: $rc"
    fi
fi

# ---------------------------------------------------------------------------
# --os darwin must refuse to run on this (Linux) machine. Darwin
# configurations are only ever classified on the macOS pool; see the
# header comment in scripts/flake-input-impact.sh.
# ---------------------------------------------------------------------------

set +e
run_script "dep-source" --os darwin >/dev/null 2>"$TMPROOT/stderr.log"
rc=$?
set -e
if [[ $rc -eq 2 ]] && grep -q "macOS pool" "$TMPROOT/stderr.log"; then
    ok
else
    bad "--os darwin on Linux must exit 2" "actual exit: $rc" "stderr:" "$(cat "$TMPROOT/stderr.log")"
fi

# ---------------------------------------------------------------------------
# (f) the bumped input breaks evaluation -> an error, never "none". An eval
#     failure swallowed as an empty fingerprint would classify a real change
#     as "none" and no update PR would ever be opened for it.
# ---------------------------------------------------------------------------

sed -i 's/value = "src-v2";/value = throw "boom: the bumped input breaks evaluation";/' "$TMPROOT/dep-source/flake.nix"
git_commit_all "$TMPROOT/dep-source" "break evaluation"

set +e
out="$(run_script "dep-source")"
rc=$?
set -e
if [[ $rc -eq 1 ]] && [[ "$out" != "none" ]] && grep -q "boom: the bumped input breaks evaluation" "$TMPROOT/stderr.log"; then
    ok
else
    bad "(f) broken eval must be an error" "actual exit: $rc" "stdout: $out" "stderr:" "$(cat "$TMPROOT/stderr.log")"
fi

# ---------------------------------------------------------------------------

printf 'flake-input-impact: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
