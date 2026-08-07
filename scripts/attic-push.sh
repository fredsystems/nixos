#!/usr/bin/env bash
#
# Push built results to the Attic binary cache, including the build-time
# closure -- not just the runtime closure.
#
# Why the build closure matters
# -----------------------------
# `attic push fred result` pushes the *runtime* closure: exactly what a
# host needs to activate a generation. It does not push the paths that
# were needed to *produce* it (stdenv, compilers, unpacked sources).
#
# The self-hosted runners start each job with a cold store, so every CI
# build re-fetches those build inputs from cache.nixos.org over the
# internet, when they could come off the LAN. Measured on maranello:
#
#   runtime closure        4,279 paths   43.2 GiB
#   build closure outputs  6,761 paths   58.6 GiB
#   build-only delta       2,482 paths   15.4 GiB
#
# +36% of disk to stop paying internet latency on every build. The first
# push is the expensive one; afterwards Attic already holds the paths and
# `attic push` skips them.
#
# .drv files are deliberately excluded. They are store paths, so they
# *can* be pushed, but they are useless in a binary cache: any machine
# that evaluates the flake regenerates them byte-identically. That skips
# ~28,700 paths per host for ~0.1 GiB of no benefit.
#
# Paths that are not valid locally are filtered out too. CI usually
# substitutes most of a closure rather than building it, so
# `--include-outputs` happily names outputs this machine never realised;
# handing those to `attic push` would fail the job.
#
# Usage (from the repository root, so `nix shell --inputs-from .` works):
#   scripts/attic-push.sh result
#   scripts/attic-push.sh result-a result-b
#
# Environment:
#   ATTIC_CACHE        cache name (default: fred)
#   ATTIC_JOBS         parallel upload jobs (default: 2)
#   ATTIC_PUSH_DRY_RUN if set to 1, print what would be pushed instead

set -euo pipefail

CACHE="${ATTIC_CACHE:-fred}"
JOBS="${ATTIC_JOBS:-2}"
DRY_RUN="${ATTIC_PUSH_DRY_RUN:-0}"

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <result> [result...]" >&2
  exit 1
fi

# Wrapper so the attic-client invocation lives in exactly one place.
attic_push() {
  if [ "$DRY_RUN" = "1" ]; then
    echo "  [dry-run] would push $# path(s)"
    return 0
  fi

  nix shell --inputs-from . nixpkgs#attic-client --command \
    attic push "$CACHE" --ignore-upstream-cache-filter -j "$JOBS" "$@"
}

# Push a newline-separated file of store paths, batching via xargs so a
# 30k-path argument list cannot blow the command-line limit.
attic_push_file() {
  local file="$1"

  if [ ! -s "$file" ]; then
    echo "  nothing new to push"
    return 0
  fi

  echo "  pushing $(wc -l <"$file") path(s)"

  if [ "$DRY_RUN" = "1" ]; then
    return 0
  fi

  # Feed the list on stdin rather than with `xargs -a`. `-a` is a GNU
  # extension and this script runs on the darwin runners too, where BSD
  # xargs rejects it outright:
  #
  #   xargs: invalid option -- a
  #
  # `-r` is fine on both.
  xargs -r nix shell --inputs-from . nixpkgs#attic-client --command \
    attic push "$CACHE" --ignore-upstream-cache-filter -j "$JOBS" <"$file"
}

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

# Runtime closures first, in a single attic invocation. Callers can pass
# a lot of paths (the flake-input archive job passes ~90), and each
# `nix shell ... --command attic` costs a couple of seconds to start.
echo "==> pushing runtime closure of $# path(s)"
attic_push "$@"

: >"$workdir/all"

for result in "$@"; do
  deriver="$(nix-store --query --deriver "$result" 2>/dev/null || true)"

  # Flake input sources and other non-derivation paths have no deriver.
  # Their runtime push above is all there is to do.
  if [ -z "$deriver" ] || [ ! -e "$deriver" ]; then
    continue
  fi

  # Every output reachable from the derivation graph, minus the .drv
  # files themselves.
  nix-store --query --requisites --include-outputs "$deriver" \
    | grep -v '\.drv$' >>"$workdir/all"
done

sort -u -o "$workdir/all" "$workdir/all"

if [ -s "$workdir/all" ]; then
  echo "==> pushing build closure"

  # Outputs this machine never realised (substituted parents, unbuilt
  # branches). attic cannot push what does not exist.
  xargs -r nix-store --check-validity --print-invalid <"$workdir/all" \
    2>/dev/null | sort -u >"$workdir/invalid" || true

  comm -23 "$workdir/all" "$workdir/invalid" >"$workdir/push"

  attic_push_file "$workdir/push"
fi
