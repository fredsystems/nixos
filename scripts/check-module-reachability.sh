#!/usr/bin/env bash
#
# check-module-reachability.sh -- detect `.nix` files that are never
# imported anywhere and are not themselves a recognised entry point.
#
# WHY THIS EXISTS
#
# `firmware.nix` used to sit in this repo, imported by nothing, while CI
# still treated any change to it as a global rebuild trigger (matching the
# broad `modules/` path pattern). It has since been deleted, so this check
# currently has no subject on the current tree -- that is fine and is the
# point: it is preventative, not remedial. A file that stops being
# imported (a rename that missed one call site, a module folded into
# another and the old file left behind) previously had no signal at all
# short of a human noticing the file never comes up in `rg` output.
#
# ENTRY POINTS (files that are live without being imported by name)
#
#   - flake.nix and everything under flake/           -- read by Nix
#     itself via the flake's own outputs, never `import`ed by a sibling
#     module.
#   - hosts/*/*/configuration.nix and
#     hosts/*/*/hardware-configuration.nix             -- wired in
#     per-host by flake/lib/mk-system.nix /
#     flake/lib/mk-darwin-system.nix via a host-name lookup, not a
#     textual import from another module.
#   - hosts/*/*/home.nix                               -- referenced the
#     same way, from the home-manager side of the same host-name lookup.
#   - profiles/*.nix                                    -- selected by
#     name from flake/hosts/servers.nix / the host's own module list, not
#     imported by basename from inside modules/.
#   - any `default.nix` reached by directory import (`import ./foo` picks
#     up `foo/default.nix` without ever spelling out the filename) -- see
#     below for how this is handled; it is not a blanket exemption.
#
# Everything else must show up, verbatim, as a substring of some OTHER
# file in the tree, or it is reported as unreachable.
#
# WHY BASENAME SUBSTRING MATCHING, NOT AN AST
#
# Nix import expressions show up in several shapes in this repo:
# `./foo.nix`, `./foo` (directory), `../../modules/x.nix`, and inside
# `lib.optional` / `lib.optionals` / `imports = [ ... ]` lists. Building a
# real Nix parser to resolve every one of these precisely is a lot of
# machinery for a check whose entire job is "does this filename appear
# anywhere else". Nix does not auto-append `.nix` to a path (unlike some
# other languages' module resolution), so a direct-file import of
# `foo.nix` must always spell the extension out literally somewhere --
# which means a plain substring search for the basename is a sound MOSTLY
# COMPLETE test for "is this file imported by name", not a heuristic
# approximation of one.
#
# `default.nix` is the one case that breaks that argument: a directory
# import spells out the DIRECTORY's name, not the literal string
# "default.nix" (see `./modules` in
# features/desktop/environments/default.nix, which resolves to
# features/desktop/environments/modules/default.nix without "default.nix"
# appearing anywhere in the importing file). So for a `default.nix`, the
# search token is its PARENT directory's basename instead of its own
# filename -- matching how every directory import in this repo is
# actually written (relative to the importing file's own directory, one
# path component at a time, never a multi-segment path pieced together
# from the repo root).
#
# FALSE-NEGATIVE / FALSE-POSITIVE TRADEOFF (chosen deliberately)
#
# This check is heavily biased toward false negatives (missing a dead
# file) over false positives (flagging a live one), for two independent
# reasons:
#
#   1. Some files are imported as plain functions rather than modules --
#      `import ../lib/home-dir.nix { ... }`, `import
#      ../lib/gitconfig-template.nix` -- which is still a literal
#      basename-with-extension reference and is picked up by the same
#      substring search with no special-casing needed.
#   2. Several `default.nix` parent-directory names are short, common
#      English words that could in principle appear elsewhere in the
#      tree by coincidence (comments, unrelated option names) even if the
#      directory itself were dead. This check accepts that risk
#      willingly: a missed dead file costs nothing (it is preventative,
#      not the thing currently broken), while a false CI failure on a
#      live module costs a wasted investigation on every affected commit.
#      "Report a file as dead only when its basename appears in no
#      import expression anywhere in the tree" is the brief this script
#      was written against, and it is interpreted literally: presence
#      anywhere, not presence in a syntactically-valid import position.
#
# Given that bias, a clean run of this script is NOT proof that every
# file is genuinely wired into a host's module tree -- only that its
# name shows up somewhere plausible. It is a tripwire for the
# `firmware.nix` failure mode (renamed/orphaned/never-added file with an
# uncommon name), not a full reachability graph.
set -euo pipefail

# Located by BASH_SOURCE, not `git rev-parse`, so this also works from
# inside the standalone flake check's sandboxed build (no .git there).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

for tool in grep find; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "error: required tool not on PATH: $tool" >&2
    echo "hint: run inside 'nix develop', or via 'nix build .#checks.\${system}.module-reachability'" >&2
    exit 1
  }
done

mapfile -t all_files < <(
  find . -name '*.nix' -not -path './.git/*' -print \
    | sed 's#^\./##' \
    | sort
)

if [[ ${#all_files[@]} -eq 0 ]]; then
  echo "error: no .nix files found (run from the repository root)" >&2
  exit 1
fi

is_entry_point() {
  case "$1" in
    flake.nix) return 0 ;;
    flake/*) return 0 ;;
    hosts/*/*/configuration.nix) return 0 ;;
    hosts/*/*/hardware-configuration.nix) return 0 ;;
    hosts/*/*/home.nix) return 0 ;;
    profiles/*.nix) return 0 ;;
    *) return 1 ;;
  esac
}

dead=()

for f in "${all_files[@]}"; do
  if is_entry_point "$f"; then
    continue
  fi

  base="$(basename "$f")"
  if [[ $base == "default.nix" ]]; then
    # Directory import: the importer spells out the directory name, not
    # "default.nix" itself. See the header comment for why this is one
    # path component, not the full path from the repo root.
    token="$(basename "$(dirname "$f")")"
    reason="directory '$(dirname "$f")' (via its basename '${token}')"
  else
    token="$base"
    reason="filename '${token}'"
  fi

  mapfile -t hits < <(
    grep -rlF --include='*.nix' --exclude-dir=.git -- "$token" . \
      | sed 's#^\./##' \
      || true
  )

  found_elsewhere=0
  for h in "${hits[@]:-}"; do
    [[ -z $h ]] && continue
    if [[ $h != "$f" ]]; then
      found_elsewhere=1
      break
    fi
  done

  if [[ $found_elsewhere -eq 0 ]]; then
    dead+=("${f}: ${reason} does not appear in any other .nix file")
  fi
done

if [[ ${#dead[@]} -gt 0 ]]; then
  echo "module reachability check FAILED:" >&2
  echo "" >&2
  for d in "${dead[@]}"; do
    echo "  - ${d}" >&2
  done
  echo "" >&2
  echo "Each of the above is not a recognised entry point (flake.nix, flake/**," >&2
  echo "a host's configuration.nix/hardware-configuration.nix/home.nix, or a" >&2
  echo "profiles/*.nix) and its name does not appear in any other .nix file in" >&2
  echo "the tree. Either wire it into an imports list / lib.optional, delete it" >&2
  echo "if it is genuinely orphaned, or -- if it is a new kind of entry point --" >&2
  echo "extend is_entry_point() in $(basename "$0") to recognise it." >&2
  exit 1
fi

echo "module reachability OK (${#all_files[@]} .nix files, none unreachable)"
