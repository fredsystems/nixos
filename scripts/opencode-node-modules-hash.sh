#!/usr/bin/env bash
# Verify the opencode node_modules fixed-output hash for the pinned release,
# and record the real one when upstream's is stale.
#
# Upstream keeps the hash per system in nix/hashes.json, updated by a bot PR
# that is not always merged before a release is tagged. This builds upstream's
# node_modules using THIS repo's complete flake.lock, including opencode/nixpkgs:
# if it builds,
# upstream's hash is right; if it fails with a hash mismatch, the "got:" hash
# is the real one. Real hashes are written to
# flake/lib/opencode-node-modules-hashes.json, which
# flake/lib/opencode-overlay.nix applies.
#
# The node_modules derivation runs `bun install` for the build platform, so a
# system's hash can only be computed on a machine of that system.
#
# Usage:
#   opencode-node-modules-hash.sh [update]
#       compute + record for this machine's system.
#   opencode-node-modules-hash.sh compute [SYSTEM]
#       Build node_modules for SYSTEM (default: this machine's) and print the
#       real hash on stdout. Progress goes to stderr.
#   opencode-node-modules-hash.sh record SYSTEM HASH
#       Record HASH for SYSTEM, keyed by both OpenCode and nixpkgs revisions.
#
# `relock` advances only opencode/nixpkgs when upstream's release lock has a
# Bun outside package.json's `^packageManager` range on any deployed system
# (flake/lib/opencode-bun.nix decides). `identity` prints the two locked
# revisions that determine the dependency hash (also used by CI's skip gate).
# Requires nix and jq.

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
lock_file="$repo_root/flake.lock"
hashes_file="$repo_root/flake/lib/opencode-node-modules-hashes.json"
flake_expr="builtins.getFlake $(jq -Rn --arg path "$repo_root" '$path')"
bun_nix="$(jq -Rn --arg path "$repo_root/flake/lib/opencode-bun.nix" '$path')"

log() { printf '%s\n' "$*" >&2; }
die() {
  log "ERROR: $*"
  exit 1
}

locked() {
  jq -r --arg field "$1" '.nodes[.nodes.root.inputs.opencode].locked[$field]' "$lock_file"
}

package_expr() {
  case "$1" in
    x86_64-linux | aarch64-linux | aarch64-darwin) ;;
    *) die "unsupported system: $1" ;;
  esac
  printf '(%s).inputs.opencode.packages.%s.opencode' "$flake_expr" "$1"
}

identity() {
  nix eval --impure --json --expr "let f = ($flake_expr); in {
    rev = f.inputs.opencode.rev;
    nixpkgsRev = f.inputs.opencode.inputs.nixpkgs.rev;
  }"
}

# Bun compatibility of the locked opencode/nixpkgs for every deployed system,
# judged by flake/lib/opencode-bun.nix (the same rule the overlay asserts).
bun_status() {
  nix eval --impure --json --expr "let
    f = ($flake_expr);
    p = f.inputs.opencode.inputs.nixpkgs;
    check = system: import (/. + $bun_nix) {
      inherit (p) lib;
      inherit (p.lib.importJSON (f.inputs.opencode + \"/package.json\")) packageManager;
      inherit (p.legacyPackages.\${system}) bun;
    };
    systems = [ \"x86_64-linux\" \"aarch64-darwin\" ];
    results = map check systems;
  in {
    range = (builtins.head results).range;
    bun = builtins.listToAttrs (map (s: { name = s; value = (check s).version; }) systems);
    compatible = builtins.all (r: r.compatible) results;
  }"
}

relock() {
  local status
  status="$(bun_status)"
  if [[ $(jq -r .compatible <<<"$status") != true ]]; then
    log "OpenCode's locked Bun does not satisfy its packageManager pin: $(jq -c . <<<"$status")"
    log "Updating only opencode/nixpkgs."
    nix flake update --flake "$repo_root" opencode/nixpkgs >&2
    status="$(bun_status)"
  fi
  [[ $(jq -r .compatible <<<"$status") == true ]] ||
    die "opencode/nixpkgs still does not provide a Bun OpenCode accepts: $(jq -c . <<<"$status")"
  log "OpenCode Bun is compatible: $(jq -c . <<<"$status")"
}

current_system() {
  nix eval --impure --raw --expr builtins.currentSystem
}

upstream_hash() {
  nix eval --impure --raw --expr "($(package_expr "$1")).node_modules.outputHash"
}

compute() {
  local system="$1" expected got
  expected="$(upstream_hash "$system")"
  log "Building locked OpenCode node_modules for $system (upstream hash $expected)"

  build_log="$(mktemp)"
  trap 'rm -f "$build_log"' EXIT
  if nix build --impure --no-link --print-build-logs --expr "($(package_expr "$system")).node_modules" 2>&1 | tee "$build_log" >&2; then
    log "Upstream hash for $system is correct."
    printf '%s\n' "$expected"
    return
  fi

  got="$(grep -oE 'got: +sha256-[A-Za-z0-9+/=]+' "$build_log" | tail -n1)"
  got="${got##* }"
  [[ -n $got ]] || die "node_modules build for $system failed for a reason other than a hash mismatch"
  log "Upstream hash for $system is stale; real hash is $got"
  printf '%s\n' "$got"
}

record() {
  local system="$1" hash="$2" rev nixpkgs_rev tmp
  [[ $hash =~ ^sha256-[A-Za-z0-9+/=]+$ ]] || die "not an SRI sha256 hash: '$hash'"
  rev="$(locked rev)"
  nixpkgs_rev="$(identity | jq -r .nixpkgsRev)"

  tmp="$(mktemp)"
  jq --arg rev "$rev" --arg nixpkgsRev "$nixpkgs_rev" --arg system "$system" --arg hash "$hash" '
    .nodeModules[$system] = {rev: $rev, nixpkgsRev: $nixpkgsRev, hash: $hash}
  ' "$hashes_file" >"$tmp"
  mv "$tmp" "$hashes_file"
  log "Recorded $system for opencode $rev: $(jq -c . "$hashes_file")"
}

cmd="${1:-update}"
case "$cmd" in
  relock) relock ;;
  identity) identity ;;
  update)
    system="$(current_system)"
    record "$system" "$(compute "$system")"
    ;;
  compute)
    compute "${2:-$(current_system)}"
    ;;
  record)
    [[ $# -eq 3 ]] || die "usage: $0 record SYSTEM HASH"
    record "$2" "$3"
    ;;
  *)
    die "unknown command '$cmd' (expected relock, identity, update, compute or record)"
    ;;
esac
