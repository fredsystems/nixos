#!/usr/bin/env bash
#
# sync-opencode-hash.sh -- keep overlays/opencode.nix's pinned hashes correct.
#
# WHY THIS EXISTS
#
# overlays/opencode.nix pins opencode to a newer upstream tag than nixpkgs
# carries, which means it must also pin the `node_modules` fixed-output
# derivation hash. That hash is a function of TWO independent variables:
#
#     outputHash = f( opencode src , nixpkgs' node_modules recipe )
#
# The original update-opencode.yaml only ever watched the first. It compared
# the pinned version against the newest upstream release and exited early when
# they matched, so between opencode releases the pinned hash was never
# revalidated. When nixpkgs changed the recipe instead -- as it did in
# d07339e1, "opencode: drop bundled Windows executables from node_modules" --
# the hash silently went stale and nothing noticed until a nixpkgs bump PR
# failed both desktop builds and a human diagnosed it by hand. That happened,
# and the one-line fix is commit a278fe87.
#
# This script owns both variables. Workflows call it; it does not care why.
#
# THE CACHE HAZARD, AND WHY THE PLACEHOLDER IS THE ANSWER TO IT
#
# A fixed-output derivation's store path is determined by its `outputHash`
# alone, NOT by its recipe. Change the recipe but keep the hash and the output
# path is byte-identical, so if that path is substitutable Nix fetches it and
# never runs the builder. A stale hash therefore looks perfectly healthy on any
# machine that can reach a cache holding the old content.
#
# That is not hypothetical. Our desktop CI jobs run on self-hosted runners with
# `substituters = http://192.168.31.14:8080/fred`, and a build of
# opencode-node_modules-1.18.18 under a *changed* nixpkgs recipe was observed
# resolving straight out of Attic with no verification whatsoever.
#
# The defence is the placeholder hash below, not a substituter flag. Nix
# validates a fixed-output derivation's content against its declared hash on
# substitution as well as on build, so a path claiming WRONG_HASH can never be
# fetched from any cache — no such content exists. Forcing the placeholder
# therefore guarantees the builder actually runs, on any machine, regardless of
# what the caches hold.
#
# Note for anyone tempted to "harden" this with --no-substitute: don't. That
# flag applies to the whole dependency closure, not just the target, so it
# would rebuild bun, stdenv and everything else from source. It buys nothing
# here — the placeholder already does the job.
#
# USAGE
#
#   sync-opencode-hash.sh [--check] [--version <v>]
#
#   (no args)     Recompute the node_modules hash for the currently pinned
#                 version and rewrite overlays/opencode.nix if it differs.
#   --check       Same, but never write. Exit 3 if the pinned hash is stale.
#                 For CI gates that should report rather than mutate.
#   --version <v> First repoint version + src hash at <v>, then recompute.
#                 Omit to revalidate whatever is currently pinned -- which is
#                 the case the old workflow could not express at all.
#
# EXIT CODES
#
#   0  Everything already correct, nothing written.
#   1  Error.
#   2  Updated overlays/opencode.nix (something was stale, now fixed).
#   3  --check only: pinned hash is stale.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OVERLAY="${REPO_ROOT}/overlays/opencode.nix"

# Any host works -- the overlay is host-independent. Daytona is used because it
# is the desktop attr the manual bump procedure in overlays/opencode.nix names.
readonly EVAL_HOST="Daytona"
readonly NODE_MODULES_ATTR=".#nixosConfigurations.${EVAL_HOST}.pkgs.opencode.node_modules"

# A syntactically valid SRI hash that cannot be the real one, used to force the
# mismatch that reveals the true hash. lib.fakeHash is the idiomatic choice but
# is not addressable from a bare sed, so an all-A hash serves the same purpose.
readonly WRONG_HASH="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

CHECK_ONLY=0
NEW_VERSION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)
            CHECK_ONLY=1
            shift
            ;;
        --version)
            [[ $# -ge 2 ]] || {
                echo "error: --version needs an argument" >&2
                exit 1
            }
            NEW_VERSION="$2"
            shift 2
            ;;
        *)
            echo "error: unknown argument '$1'" >&2
            exit 1
            ;;
    esac
done

[[ -f "$OVERLAY" ]] || {
    echo "error: $OVERLAY not found" >&2
    exit 1
}

# Read a `<key> = "<value>";` assignment out of the overlay. Deliberately
# anchored per-key: `src.hash` uses `hash` while node_modules uses
# `outputHash`, and a loose pattern would clobber the wrong one.
read_pin() {
    sed -n "s/^[[:space:]]*$1 = \"\(.*\)\";/\1/p" "$OVERLAY" | head -1
}

# `|` as the sed delimiter throughout: SRI base64 can contain `/`, which would
# terminate a `/`-delimited substitution mid-hash.
write_pin() {
    sed -i "s|^\([[:space:]]*\)$1 = \".*\";|\1$1 = \"$2\";|" "$OVERLAY"
}

CURRENT_VERSION="$(read_pin version)"
[[ -n "$CURRENT_VERSION" ]] || {
    echo "error: could not read the pinned version from $OVERLAY" >&2
    exit 1
}

CHANGED=0

if [[ -n "$NEW_VERSION" && "$NEW_VERSION" != "$CURRENT_VERSION" ]]; then
    if [[ "$CHECK_ONLY" -eq 1 ]]; then
        echo "error: --check and --version are mutually exclusive" >&2
        exit 1
    fi

    echo "==> repointing opencode ${CURRENT_VERSION} -> ${NEW_VERSION}" >&2

    src_hash="$(nix run nixpkgs#nix-prefetch-github -- \
        anomalyco opencode --rev "v${NEW_VERSION}" | jq -r .hash)"
    [[ -n "$src_hash" && "$src_hash" != "null" ]] || {
        echo "error: could not prefetch the source hash for v${NEW_VERSION}" >&2
        exit 1
    }

    write_pin version "$NEW_VERSION"
    write_pin hash "$src_hash"
    CURRENT_VERSION="$NEW_VERSION"
    CHANGED=1
fi

PINNED_HASH="$(read_pin outputHash)"
echo "==> pinned: opencode ${CURRENT_VERSION}, node_modules ${PINNED_HASH}" >&2

# Force the mismatch that reveals the true hash. Restored on every exit path so
# a failure part-way through cannot leave the placeholder committed -- that
# would be a silently poisoned overlay.
restore_overlay() {
    if [[ -n "${OVERLAY_BACKUP:-}" && -f "$OVERLAY_BACKUP" ]]; then
        mv "$OVERLAY_BACKUP" "$OVERLAY"
    fi
}
OVERLAY_BACKUP="$(mktemp)"
cp "$OVERLAY" "$OVERLAY_BACKUP"
trap restore_overlay EXIT

write_pin outputHash "$WRONG_HASH"

echo "==> rebuilding node_modules (forced via placeholder hash)" >&2

# The placeholder hash guarantees a real build rather than a cache hit; see the
# header for why that is the right mechanism and --no-substitute is not.
# The build is EXPECTED to fail: a fixed-output derivation whose content does
# not match its declared hash is exactly how the real hash is discovered.
BUILD_LOG="$(mktemp)"
if nix build "$NODE_MODULES_ATTR" --no-link >"$BUILD_LOG" 2>&1; then
    echo "error: expected a hash mismatch but the build succeeded." >&2
    echo "       That means the placeholder hash was accepted, which should be" >&2
    echo "       impossible -- check that write_pin actually rewrote outputHash." >&2
    rm -f "$BUILD_LOG"
    exit 1
fi

# Nix reports a mismatch as an adjacent pair:
#
#     specified: <declared hash>
#        got:    <actual hash>
#
# Take the `got:` belonging to the pair whose `specified:` is our placeholder,
# NOT simply the first `got:` in the log. A dependency that fails its own hash
# check earlier in the build emits the same shape, and picking that one would
# write another derivation's hash into outputHash -- a silently poisoned pin
# that still looks well-formed. Only our target can have WRONG_HASH declared,
# so pairing on it identifies the right block unambiguously.
#
# Anything else means the build failed for an unrelated reason and must not be
# papered over, so an absent pair keeps the error path below.
REAL_HASH="$(
    awk -v wrong_hash="$WRONG_HASH" '
        $1 == "specified:" && $2 == wrong_hash { want_got = 1; next }
        want_got && $1 == "got:" { print $2; exit }
    ' "$BUILD_LOG"
)"
if [[ -z "$REAL_HASH" ]]; then
    echo "error: node_modules failed to build for a reason other than a hash" >&2
    echo "       mismatch. Full log follows." >&2
    cat "$BUILD_LOG" >&2
    rm -f "$BUILD_LOG"
    exit 1
fi
rm -f "$BUILD_LOG"

restore_overlay
trap - EXIT
OVERLAY_BACKUP=""

if [[ "$REAL_HASH" == "$PINNED_HASH" ]]; then
    echo "==> node_modules hash is correct" >&2
    [[ "$CHANGED" -eq 1 ]] && exit 2
    exit 0
fi

echo "==> node_modules hash is STALE" >&2
echo "      pinned: ${PINNED_HASH}" >&2
echo "      actual: ${REAL_HASH}" >&2

if [[ "$CHECK_ONLY" -eq 1 ]]; then
    echo "==> --check: not writing" >&2
    exit 3
fi

write_pin outputHash "$REAL_HASH"
echo "==> updated ${OVERLAY}" >&2
exit 2
