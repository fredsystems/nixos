#!/usr/bin/env bash
#
# check-doc-drift.sh -- catch two "in sync by luck" invariants that used to
# have no machine enforcement at all:
#
#   1. MODULES.md documents exactly the modules exported by
#      `nixosModules` -- no more, no less.
#   2. The desktop/server host split is consistent: `desktop_names` in
#      ci-linux.yaml is a subset of `nixosConfigurations`, and every
#      remaining ("server") host has a matching entry in
#      flake/hosts/servers.nix.
#
# WHY THIS EXISTS
#
# MODULES.md was last hand-edited 2026-02-11; modules/ has had commits
# since. Nothing re-derives the doc from the module set, so a module
# add/rename/removal silently goes undocumented (or the doc silently goes
# stale) until a human happens to notice. Same story for the host split:
# `desktop_names=("Daytona" "maranello")` in ci-linux.yaml and the node
# table in flake/hosts/servers.nix are two independent hand-maintained
# lists that must describe the same fleet.
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
# The desktop-host extraction mirrors, byte-for-byte, the grep/tr
# pipeline `impacted-hosts.sh` already uses to read `desktop_names` out
# of ci-linux.yaml, so there is exactly one parser for that array, not
# two that can disagree.
#
# NIX-EVAL INJECTION
#
# Three of the sets this script compares (`nixosModules` attribute names,
# `nixosConfigurations` attribute names, and flake/hosts/servers.nix's
# attribute names) are, at heart, already-evaluated Nix values -- `self`
# already has them in flake/dev/checks.nix. Shelling out to `nix eval`
# for them here is the right thing to do when this script runs directly
# (as a human, or as the pre-commit hook, both of which run outside the
# Nix build sandbox with full daemon access) but would NOT work from
# inside the standalone `checks.doc-drift` derivation: sandboxed builds
# have no daemon-socket access, so a `nix eval` call from within one just
# hangs or errors. So each of the three accepts an optional
# pre-computed-JSON override via environment variable; the standalone
# check sets all three from pure Nix (no IFD, no network) and this script
# skips the `nix eval` call entirely when they're set.
set -euo pipefail

# Located by BASH_SOURCE, not `git rev-parse`, so this also works from
# inside the standalone flake check's sandboxed build (no .git there).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

MODULES_MD="MODULES.md"
CI_LINUX=".github/workflows/ci-linux.yaml"
SERVERS_NIX="flake/hosts/servers.nix"

for f in "$MODULES_MD" "$CI_LINUX" "$SERVERS_NIX"; do
  if [[ ! -f $f ]]; then
    echo "error: $f not found (run from the repository root)" >&2
    exit 1
  fi
done

errors=()

# ---------------------------------------------------------------------------
# 1. nixosModules vs MODULES.md
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# 2. desktop/server host split
# ---------------------------------------------------------------------------

all_systems_json="${ALL_SYSTEMS_JSON:-$(nix eval --json .#nixosConfigurations --apply builtins.attrNames)}"
mapfile -t all_systems < <(jq -r '.[]' <<<"$all_systems_json" | sort -u)

# Mirrors impacted-hosts.sh's own extraction of `desktop_names` verbatim, so
# there is exactly one parser for this array.
mapfile -t desktop_names < <(
  grep -oE 'desktop_names=\("[^)]*"\)' "$CI_LINUX" \
    | tr ' ' '\n' \
    | grep -oE '"[A-Za-z0-9_-]+"' \
    | tr -d '"' || true
)

if [[ ${#desktop_names[@]} -eq 0 ]]; then
  errors+=("could not parse a \`desktop_names=(...)\` array out of ${CI_LINUX}")
fi

mapfile -t desktop_not_a_system < <(comm -23 \
  <(printf '%s\n' "${desktop_names[@]}" | sort -u) \
  <(printf '%s\n' "${all_systems[@]}"))

for d in "${desktop_not_a_system[@]}"; do
  [[ -n $d ]] && errors+=(
    "${CI_LINUX}: desktop_names lists '${d}', which is not a nixosConfigurations host (typo, or a renamed/removed desktop)"
  )
done

mapfile -t computed_servers < <(comm -23 \
  <(printf '%s\n' "${all_systems[@]}") \
  <(printf '%s\n' "${desktop_names[@]}" | sort -u))

servers_nix_json="${SERVERS_NIX_KEYS_JSON:-$(nix eval --json --file "$SERVERS_NIX" --apply builtins.attrNames)}"
mapfile -t servers_nix_keys < <(jq -r '.[]' <<<"$servers_nix_json" | sort -u)

mapfile -t missing_from_servers_nix < <(comm -23 \
  <(printf '%s\n' "${computed_servers[@]}") \
  <(printf '%s\n' "${servers_nix_keys[@]}"))

mapfile -t stale_in_servers_nix < <(comm -13 \
  <(printf '%s\n' "${computed_servers[@]}") \
  <(printf '%s\n' "${servers_nix_keys[@]}"))

for s in "${missing_from_servers_nix[@]}"; do
  [[ -n $s ]] && errors+=(
    "'${s}' is a nixosConfigurations host, not in desktop_names, but has no entry in ${SERVERS_NIX} (add one)"
  )
done

for s in "${stale_in_servers_nix[@]}"; do
  [[ -n $s ]] && errors+=(
    "${SERVERS_NIX} has an entry for '${s}', which is not a server host -- either it is not in nixosConfigurations at all, or it is listed in desktop_names in ${CI_LINUX} (remove the stale entry, or fix desktop_names)"
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

echo "doc drift OK (${#actual_modules[@]} modules documented, ${#all_systems[@]} hosts split ${#desktop_names[@]} desktop / ${#computed_servers[@]} server, all in sync)"
