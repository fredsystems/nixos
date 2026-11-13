#!/usr/bin/env bash
#
# impacted-hosts-test.sh -- hermetic tests for scripts/impacted-hosts.sh.
#
# Copies the fixture flake (scripts/tests/fixtures/impacted-hosts/) into a
# scratch git repo, then makes one commit per case and asks the script what
# that commit impacts relative to its parent, for both --target hosts and
# --target dev. Fully offline and fast: the fixture has no inputs and its
# outputs are `builtins.derivation`s that are only ever hashed, never built.
#
# Usage: bash scripts/tests/impacted-hosts-test.sh   (from the repo root)

set -euo pipefail

# Run from a git hook, git exports GIT_INDEX_FILE, GIT_DIR and friends.
# Left set, every git command below would act on the repository being
# committed instead of the scratch one. (env + sed, not compgen: Nix's
# minimal bash has no compgen.)
for var in $(env | sed -n 's/^\(GIT_[A-Za-z0-9_]*\)=.*/\1/p'); do
    unset "$var"
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/impacted-hosts.sh"
FIXTURE="$ROOT/scripts/tests/fixtures/impacted-hosts"

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); }
bad() {
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n' "$1" >&2
    [[ $# -lt 2 ]] || printf '      %s\n' "${@:2}" >&2
}

TMPROOT="$(mktemp -d)"
trap 'chmod -R u+w "$TMPROOT" 2>/dev/null; rm -rf "$TMPROOT"' EXIT

# Hermetic Nix, as in flake-input-impact-test.sh: a throwaway store, state
# dir and config, so this runs inside the Nix build sandbox (the
# pre-commit-check and impacted-hosts flake checks) and never touches the
# real store.
export HOME="$TMPROOT/home"
export NIX_STATE_DIR="$TMPROOT/nix-state"
export NIX_CONF_DIR="$TMPROOT/nix-conf"
export NIX_CONFIG="store = $TMPROOT/nix-store
experimental-features = nix-command flakes"
mkdir -p "$HOME" "$NIX_CONF_DIR"

SYSTEM="$(nix eval --impure --raw --expr builtins.currentSystem)"
case "$SYSTEM" in
    *-linux) OS="linux" OTHER_OS="darwin" ;;
    *-darwin) OS="darwin" OTHER_OS="linux" ;;
    *)
        echo "unrecognised system $SYSTEM" >&2
        exit 1
        ;;
esac

REPO="$TMPROOT/repo"
cp -R "$FIXTURE" "$REPO"
chmod -R u+w "$REPO"
mkdir -p "$REPO/hosts/linux/alpha" "$REPO/hosts/linux/beta" "$REPO/hosts/darwin/mac" \
    "$REPO/modules" "$REPO/dev" "$REPO/pkgs" "$REPO/scripts"
echo v1 >"$REPO/hosts/linux/alpha/marker"
echo v1 >"$REPO/hosts/linux/beta/marker"
echo v1 >"$REPO/hosts/darwin/mac/marker"
echo v1 >"$REPO/modules/common"
echo v1 >"$REPO/dev/shell"
echo v1 >"$REPO/pkgs/tool"
echo v1 >"$REPO/README.md"
echo v1 >"$REPO/scripts/attic-push.sh"

commit() { # message
    git -C "$REPO" add -A
    git -C "$REPO" -c user.email=test@example.com -c user.name=test commit -q -m "$1"
}

git -C "$REPO" init -q
commit "init"

# change <file...>: append to each file, commit, and leave HEAD~1 as base.
change() {
    local f
    for f in "$@"; do
        mkdir -p "$(dirname "$REPO/$f")"
        echo changed >>"$REPO/$f"
    done
    commit "change $*"
}

run() { # args...
    (cd "$REPO" && bash "$SCRIPT" --os "$OS" --committed-only --json "$@" HEAD~1) 2>"$TMPROOT/stderr.log"
}

# expect <name> <expected compact JSON> <script args...>
expect() {
    local name="$1" expected="$2" actual
    shift 2
    if actual="$(run "$@")"; then
        # Order-insensitive: compare with the list sorted.
        actual="$(jq -c 'with_entries(if (.value | type) == "array" then .value |= sort else . end)' <<<"$actual")"
        if [[ "$actual" == "$expected" ]]; then
            ok
        else
            bad "$name" "expected: $expected" "actual:   $actual" "stderr:" "$(cat "$TMPROOT/stderr.log")"
        fi
    else
        bad "$name" "script failed" "stderr:" "$(cat "$TMPROOT/stderr.log")"
    fi
}

if [[ "$OS" == "linux" ]]; then
    ALL_HOSTS='["Alpha","beta"]'
    HOST_DIR="hosts/linux/alpha/marker"
    HOST_ONE='["Alpha"]'
else
    ALL_HOSTS='["mac"]'
    HOST_DIR="hosts/darwin/mac/marker"
    HOST_ONE='["mac"]'
fi
SHELL_OUT="devShells.$SYSTEM.default"
TOOL_OUT="packages.$SYSTEM.tool"

# Docs only: inert for both targets, answered without an eval.
change README.md
expect "docs-only hosts" '{"mode":"force-none","hosts":[]}'
expect "docs-only dev" '{"mode":"force-none","outputs":[]}' --target dev

# A host directory: host-confined for hosts (folding case: Alpha vs
# alpha), but the dev target must not trust that and diffs for real.
change "$HOST_DIR"
expect "host dir hosts" "{\"mode\":\"host-confined\",\"hosts\":$HOST_ONE}"
expect "host dir dev" '{"mode":"eval-diff","outputs":[]}' --target dev

# A shared module: every host, no dev output.
change modules/common
expect "shared module hosts" "{\"mode\":\"eval-diff\",\"hosts\":$ALL_HOSTS}"
expect "shared module dev" '{"mode":"eval-diff","outputs":[]}' --target dev

# The overlay case the old path-list detector missed: a file outside any
# list changes one package and nothing else.
change pkgs/tool
expect "package source hosts" '{"mode":"eval-diff","hosts":[]}'
expect "package source dev" "{\"mode\":\"eval-diff\",\"outputs\":[\"$TOOL_OUT\"]}" --target dev

change dev/shell
expect "dev shell dev" "{\"mode\":\"eval-diff\",\"outputs\":[\"$SHELL_OUT\"]}" --target dev

# A new package exists only at HEAD and must still be reported.
change pkgs/newtool
expect "new package dev" "{\"mode\":\"eval-diff\",\"outputs\":[\"packages.$SYSTEM.newtool\"]}" --target dev

# A CI pipeline file (FORCE_ALL_FILES): everything, without an eval.
change scripts/attic-push.sh
expect "pipeline file hosts" "{\"mode\":\"force-all\",\"hosts\":$ALL_HOSTS}"
expect "pipeline file dev" "{\"mode\":\"force-all\",\"outputs\":[\"$SHELL_OUT\",\"packages.$SYSTEM.newtool\",\"$TOOL_OUT\"]}" --target dev

# --target dev reports this machine's outputs, so a mismatched --os is an
# error rather than a silently wrong answer.
if (cd "$REPO" && bash "$SCRIPT" --os "$OTHER_OS" --target dev --committed-only --json HEAD~1) >/dev/null 2>"$TMPROOT/stderr.log"; then
    bad "dev with mismatched --os must fail"
elif grep -q "is not --os $OTHER_OS" "$TMPROOT/stderr.log"; then
    ok
else
    bad "dev with mismatched --os: wrong error" "$(cat "$TMPROOT/stderr.log")"
fi

if (cd "$REPO" && bash "$SCRIPT" --os "$OS" --target bogus HEAD~1) >/dev/null 2>"$TMPROOT/stderr.log"; then
    bad "unknown --target must fail"
else
    ok
fi

printf 'impacted-hosts-test: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
