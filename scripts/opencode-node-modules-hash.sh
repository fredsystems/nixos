#!/usr/bin/env bash
# Verify the opencode node_modules fixed-output hash for the pinned release,
# and record the real one when upstream's is stale.
#
# Upstream keeps the hash per system in nix/hashes.json, updated by a bot PR
# that is not always merged before a release is tagged. This builds upstream's
# node_modules derivation for the release locked in flake.lock: if it builds,
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
#       Record HASH for SYSTEM. If it equals upstream's hash, SYSTEM's entry
#       is dropped instead (and the file is left alone if it belongs to an
#       older revision), so a correct upstream hash produces no change.
#
# Requires nix and jq.

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
lock_file="$repo_root/flake.lock"
hashes_file="$repo_root/flake/lib/opencode-node-modules-hashes.json"

log() { printf '%s\n' "$*" >&2; }
die() {
  log "ERROR: $*"
  exit 1
}

locked() {
  jq -r --arg field "$1" '.nodes[.nodes.root.inputs.opencode].locked[$field]' "$lock_file"
}

upstream_ref() {
  local type
  type="$(locked type)"
  [[ $type == github ]] || die "opencode input is locked as type '$type'; only github is supported"
  printf 'github:%s/%s/%s\n' "$(locked owner)" "$(locked repo)" "$(locked rev)"
}

current_system() {
  nix eval --impure --raw --expr builtins.currentSystem
}

upstream_hash() {
  nix eval --raw "$(upstream_ref)#packages.$1.opencode.node_modules.outputHash"
}

compute() {
  local system="$1" ref expected got
  ref="$(upstream_ref)"
  expected="$(upstream_hash "$system")"
  log "Building $ref node_modules for $system (upstream hash $expected)"

  build_log="$(mktemp)"
  trap 'rm -f "$build_log"' EXIT
  if nix build --no-link --print-build-logs "$ref#packages.$system.opencode.node_modules" 2>&1 | tee "$build_log" >&2; then
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
  local system="$1" hash="$2" rev upstream tmp
  [[ $hash =~ ^sha256-[A-Za-z0-9+/=]+$ ]] || die "not an SRI sha256 hash: '$hash'"
  rev="$(locked rev)"
  upstream="$(upstream_hash "$system")"

  tmp="$(mktemp)"
  jq --arg rev "$rev" --arg system "$system" --arg hash "$hash" --arg upstream "$upstream" '
    if $hash == $upstream then
      if .rev == $rev then del(.nodeModules[$system]) else . end
    else
      (if .rev == $rev then . else { rev: $rev, nodeModules: {} } end)
      | .nodeModules[$system] = $hash
    end
  ' "$hashes_file" >"$tmp"
  mv "$tmp" "$hashes_file"
  log "Recorded $system for opencode $rev: $(jq -c . "$hashes_file")"
}

cmd="${1:-update}"
case "$cmd" in
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
    die "unknown command '$cmd' (expected update, compute or record)"
    ;;
esac
