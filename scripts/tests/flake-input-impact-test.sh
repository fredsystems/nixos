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

# Run from a git hook (pre-commit at `git commit` time), git exports
# GIT_INDEX_FILE, GIT_DIR and friends. Left set, every git command below
# would act on the repository being committed instead of the scratch ones
# this suite creates -- it once rewrote the real index as a mass deletion.
# (env + sed, not compgen: Nix's minimal bash has no compgen.)
for var in $(env | sed -n 's/^\(GIT_[A-Za-z0-9_]*\)=.*/\1/p'); do
    unset "$var"
done

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
# Store paths are read-only, so the private store below needs its write bit
# back before it can be removed.
trap 'chmod -R u+w "$TMPROOT" 2>/dev/null; rm -rf "$TMPROOT"' EXIT

# Hermetic Nix: a throwaway store, state dir and config under TMPROOT, for
# every `nix` this suite and the script under test run (NIX_CONFIG is
# inherited). Locking and evaluating the fixtures only writes sources into
# the store and never builds, so no daemon, profile or substituter is
# needed. This is what lets the suite run inside the Nix build sandbox (the
# pre-commit-check and flake-input-impact flake checks), where the system
# store's state dir is not writable; it also keeps a local run from
# touching the real store.
export HOME="$TMPROOT/home"
export NIX_STATE_DIR="$TMPROOT/nix-state"
export NIX_CONF_DIR="$TMPROOT/nix-conf"
export NIX_CONFIG="store = $TMPROOT/nix-store
experimental-features = nix-command flakes"
mkdir -p "$HOME" "$NIX_CONF_DIR"
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
    # The fixtures may come from a read-only store path (the standalone
    # flake check runs from ${self}), and cp keeps their modes.
    chmod -R u+w "$TMPROOT/$name"
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
chmod -R u+w "$TMPROOT/nixpkgs-owned-src-v1"
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
chmod -R u+w "$TMPROOT/nixpkgs-owned-src-v2"
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

# --json reports the bumped revision it classified, which callers compare
# against the revision they planned for.
if json="$(run_script "dep-source" --json)"; then
    expected_rev="$(git -C "$TMPROOT/dep-source" rev-parse HEAD)"
    if [[ "$(jq -r .kind <<<"$json") $(jq -r .rev <<<"$json")" == "source $expected_rev" ]]; then
        ok
    else
        bad "(d) --json kind and rev" "expected: source $expected_rev" "actual: $json"
    fi
else
    bad "(d) --json" "script failed" "stderr:" "$(cat "$TMPROOT/stderr.log")"
fi

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
# --os for the OTHER operating system must be refused (exit 2): each OS's
# configurations are classified only on a runner of that OS (Darwin on the
# macOS pool, never on Linux). Works on either OS.
# ---------------------------------------------------------------------------

case "$(uname -s)" in
    Linux) other_os=darwin ;;
    Darwin) other_os=linux ;;
    *) other_os="" ;;
esac
if [[ -n "$other_os" ]]; then
    set +e
    run_script "dep-source" --os "$other_os" >/dev/null 2>"$TMPROOT/stderr.log"
    rc=$?
    set -e
    if [[ $rc -eq 2 ]] && grep -q "macOS pool" "$TMPROOT/stderr.log"; then
        ok
    else
        bad "--os $other_os on $(uname -s) must exit 2" "actual exit: $rc" "stderr:" "$(cat "$TMPROOT/stderr.log")"
    fi
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
# (g) a thrown error whose text looks like Nix's "no such output" diagnostic
#     is still an evaluation error -> exit 1, never treated as an empty
#     (missing) output.
# ---------------------------------------------------------------------------

sed -i "s/value = throw \"boom: the bumped input breaks evaluation\";/value = throw \"flake 'x' does not provide attribute 'packages'\";/" "$TMPROOT/dep-source/flake.nix"
git_commit_all "$TMPROOT/dep-source" "throw the missing-output phrase"

set +e
out="$(run_script "dep-source")"
rc=$?
set -e
if [[ $rc -eq 1 ]] && [[ "$out" != "none" ]]; then
    ok
else
    bad "(g) thrown missing-output phrase must be an error" "actual exit: $rc" "stdout: $out" "stderr:" "$(cat "$TMPROOT/stderr.log")"
fi

# ---------------------------------------------------------------------------
# (h) flake.nix and its flake.lock disagree -> exit 1, and the real lock is
#     left byte-for-byte unchanged (the baseline never re-resolves it).
#     Last case: it leaves the consumer out of sync.
# ---------------------------------------------------------------------------

sed -i 's#dep-source.url = "git+file://#dep-extra.url = "git+file://'"$TMPROOT"'/dep-follow";\n    dep-source.url = "git+file://#' "$TMPROOT/consumer/flake.nix"
git_commit_all "$TMPROOT/consumer" "add an input the lock does not know"
lock_before="$(sha256sum "$TMPROOT/consumer/flake.lock")"

set +e
out="$(run_script "dep-follow")"
rc=$?
set -e
lock_after="$(sha256sum "$TMPROOT/consumer/flake.lock")"
if [[ $rc -eq 1 ]] && [[ "$lock_before" == "$lock_after" ]] && grep -q "dep-extra" "$TMPROOT/consumer/flake.nix"; then
    ok
else
    bad "(h) out-of-sync lock must fail without touching flake.lock" "actual exit: $rc" "stdout: $out" "lock changed: $([[ "$lock_before" == "$lock_after" ]] && echo no || echo YES)" "stderr:" "$(cat "$TMPROOT/stderr.log")"
fi

# ---------------------------------------------------------------------------

printf 'flake-input-impact: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
