#!/usr/bin/env bash
#
# check-owned-nixpkgs.sh -- verify that every root flake input that keeps
# its OWN nixpkgs (does not follow one of ours) has a documented reason in
# flake.nix.
#
# WHY THIS EXISTS
#
# nixos-needsreboot built every Linux host's copy against its own nixpkgs,
# pinned to an EOL channel, because nothing flagged that it had its own
# nixpkgs node at all -- see PLAN_03_FLAKE_INPUT_TRACKING.md. An owned
# nixpkgs is sometimes the right call (a binary cache built against it, a
# hash tied to upstream's own toolchain) and sometimes just an oversight.
# This check does not decide which; it only insists the choice is written
# down next to the input, as a `# NOTE:` comment, so it survives review
# and a future audit does not have to re-derive it from the lock file.
#
# WHAT THIS CHECKS
#
# From flake.lock: for every input of the root node, resolve its locked
# node. If that node's own `inputs.nixpkgs` is a plain node name (not a
# `follows` array), the input owns its nixpkgs. For each such input, the
# line `<input> = {` must exist in flake.nix, and the contiguous run of
# comment lines directly above it (no blank line in between) must include
# at least one `# NOTE:` line.
#
# Usage: bash scripts/check-owned-nixpkgs.sh [LOCK] [FLAKE_NIX]
#   LOCK      path to flake.lock (default: ./flake.lock)
#   FLAKE_NIX path to flake.nix  (default: ./flake.nix)
set -euo pipefail

LOCK="${1:-flake.lock}"
FLAKE_NIX="${2:-flake.nix}"

for f in "$LOCK" "$FLAKE_NIX"; do
  if [[ ! -f "$f" ]]; then
    echo "error: $f not found" >&2
    exit 1
  fi
done

# <input> <node> pairs, one per line, for every root input whose resolved
# node owns its nixpkgs (its own inputs.nixpkgs is a node name, not a
# follows array). Root inputs that are themselves a follows path own
# nothing and are skipped.
owning="$(
  jq -r '
    . as $lock
    | $lock.nodes.root.inputs
    | to_entries[]
    | select(.value | type == "string")
    | .key as $input
    | .value as $node
    | ($lock.nodes[$node].inputs.nixpkgs) as $nx
    | select($nx != null and ($nx | type == "string"))
    | "\($input)\t\($node)"
  ' "$LOCK"
)"

errors=()

while IFS=$'\t' read -r input node; do
  [[ -z "$input" ]] && continue

  attr_line="$(grep -nE "^[[:space:]]*${input} = \\{" "$FLAKE_NIX" | head -1 || true)"
  if [[ -z "$attr_line" ]]; then
    errors+=("  ${input}: owns its nixpkgs (lock node ${node}) but has no \"# NOTE:\" reason directly above \"${input} = {\" in flake.nix")
    continue
  fi

  lineno="${attr_line%%:*}"

  # Walk upward from the line directly above the attr, collecting the
  # contiguous run of comment lines (first non-space char is '#'); stop at
  # the first line that is not a comment (including a blank line).
  has_note=0
  l=$((lineno - 1))
  while ((l >= 1)); do
    line="$(sed -n "${l}p" "$FLAKE_NIX")"
    trimmed="${line#"${line%%[![:space:]]*}"}"
    [[ "$trimmed" == \#* ]] || break
    [[ "$trimmed" == "# NOTE:"* ]] && has_note=1
    l=$((l - 1))
  done

  if ((has_note == 0)); then
    errors+=("  ${input}: owns its nixpkgs (lock node ${node}) but has no \"# NOTE:\" reason directly above \"${input} = {\" in flake.nix")
  fi
done <<<"$owning"

owning_count=0
[[ -z "$owning" ]] || owning_count="$(wc -l <<<"$owning")"

if [[ ${#errors[@]} -gt 0 ]]; then
  for e in "${errors[@]}"; do
    echo "$e" >&2
  done
  echo 'Either follow our nixpkgs (inputs.nixpkgs.follows = "nixpkgs") or add a "# NOTE:" comment saying what keeping its own nixpkgs gains (a binary cache, a hash tied to upstream'"'"'s toolchain, ...).' >&2
  exit 1
fi

echo "owned-nixpkgs: all ${owning_count} inputs that keep their own nixpkgs document why"
