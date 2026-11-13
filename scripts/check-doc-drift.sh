#!/usr/bin/env bash
#
# check-doc-drift.sh -- catch an "in sync by luck" invariant that used to
# have no machine enforcement at all: MODULES.md documents exactly the
# modules exported by `nixosModules` -- no more, no less.
#
# (It also used to check ci-linux.yaml's hand-maintained `desktop_names`
# against flake/hosts/servers.nix. CI no longer splits desktops from
# servers, so that list and its check are gone; in Nix the split holds by
# construction in flake/hosts/nixos.nix.)
#
# WHY THIS EXISTS
#
# MODULES.md was last hand-edited 2026-02-11; modules/ has had commits
# since. Nothing re-derives the doc from the module set, so a module
# add/rename/removal silently goes undocumented (or the doc silently goes
# stale) until a human happens to notice.
#
# PARSING STRATEGY
#
# MODULES.md's module list is derived from its own heading/bullet
# structure rather than duplicated into a second hand-maintained list in
# this script -- a second list would itself be a drift surface. Two
# doc conventions carry a module name:
#
#   - a `#### `nixosModules.NAME`` heading (the fully-documented modules)
#   - a `- **`nixosModules.NAME`**` bullet (the "individual hardware
#     modules" quick-reference list)
#
# NIX-EVAL INJECTION
#
# The set this script compares against (`nixosModules` attribute names)
# is, at heart, an already-evaluated Nix value -- `self` already has it in
# flake/dev/checks.nix. Shelling out to `nix eval`
# for them here is the right thing to do when this script runs directly
# (as a human, or as the pre-commit hook, both of which run outside the
# Nix build sandbox with full daemon access) but would NOT work from
# inside the standalone `checks.doc-drift` derivation: sandboxed builds
# have no daemon-socket access, so a `nix eval` call from within one just
# hangs or errors. So it accepts an optional pre-computed-JSON override
# via environment variable (ACTUAL_MODULES_JSON); the standalone check
# sets it from pure Nix (no IFD, no network) and this script skips the
# `nix eval` call entirely when it is set.
set -euo pipefail

# Located by BASH_SOURCE, not `git rev-parse`, so this also works from
# inside the standalone flake check's sandboxed build (no .git there).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

MODULES_MD="MODULES.md"

# Actionable message on a missing tool, matching gen-fleet-manifest.sh and
# check-colmena-parity.sh. `nix` is only needed on the bare-invocation path;
# the hook and flake check bake the expected values in at Nix eval time
# (see ACTUAL_MODULES_JSON below) precisely because git-hooks.nix runs the
# whole suite in a sandbox with nix-command disabled.
for tool in jq grep; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "error: required tool not on PATH: $tool" >&2
    echo "hint: run inside 'nix develop', or via 'nix build .#checks.\${system}.doc-drift'" >&2
    exit 1
  }
done

if [[ -z ${ACTUAL_MODULES_JSON:-} ]] && ! command -v nix >/dev/null 2>&1; then
  echo "error: nix is not on PATH and ACTUAL_MODULES_JSON was not supplied" >&2
  echo "hint: run inside 'nix develop', or via 'nix build .#checks.\${system}.doc-drift'" >&2
  exit 1
fi

if [[ ! -f $MODULES_MD ]]; then
  echo "error: $MODULES_MD not found (run from the repository root)" >&2
  exit 1
fi

errors=()

actual_modules_json="${ACTUAL_MODULES_JSON:-$(nix eval --json .#nixosModules --apply builtins.attrNames)}"
mapfile -t actual_modules < <(jq -r '.[]' <<<"$actual_modules_json" | sort -u)

mapfile -t documented_modules < <(
  {
    # shellcheck disable=SC2016 # single-quoted regex, not shell interpolation
    grep -oP '^#{2,6}\s+`nixosModules\.\K[a-zA-Z0-9_-]+(?=`\s*$)' "$MODULES_MD" || true
    # shellcheck disable=SC2016 # single-quoted regex, not shell interpolation
    grep -oP '^-\s+\*\*`nixosModules\.\K[a-zA-Z0-9_-]+(?=`\*\*)' "$MODULES_MD" || true
  } | sort -u
)

mapfile -t undocumented < <(comm -23 \
  <(printf '%s\n' "${actual_modules[@]}") \
  <(printf '%s\n' "${documented_modules[@]}"))

mapfile -t stale_docs < <(comm -13 \
  <(printf '%s\n' "${actual_modules[@]}") \
  <(printf '%s\n' "${documented_modules[@]}"))

for m in "${undocumented[@]}"; do
  [[ -n $m ]] && errors+=(
    "nixosModules.${m} exists but is not documented in ${MODULES_MD} (add a heading or bullet for it)"
  )
done

for m in "${stale_docs[@]}"; do
  [[ -n $m ]] && errors+=(
    "${MODULES_MD} documents nixosModules.${m}, which no longer exists (remove it, or check for a rename)"
  )
done

if [[ ${#errors[@]} -gt 0 ]]; then
  echo "doc drift FAILED:" >&2
  echo "" >&2
  for e in "${errors[@]}"; do
    echo "  - ${e}" >&2
  done
  exit 1
fi

echo "doc drift OK (${#actual_modules[@]} modules documented, all in sync)"
