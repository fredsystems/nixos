#!/usr/bin/env bash
# scripts/flake-input-impact.sh
#
# Classify what bumping ONE root flake input would do to what we ship, by
# evaluation only -- never building. Reuses the same "diff host toplevel
# outPaths" idea as scripts/impacted-hosts.sh, extended to the dev shell
# and packages.*, and extended again with a third evaluation that can tell
# "this input's own code changed" apart from "this input just carried its
# own (owned, not-followed) nixpkgs along for the ride" -- the niri/
# colmena/catppuccin case described in agent-docs/plans/
# PLAN_03_FLAKE_INPUT_TRACKING.md ("Impact is decided by evaluation, not by
# file names").
#
# Usage:
#   scripts/flake-input-impact.sh [--flake DIR] [--os linux|darwin|auto] [--json] <input>
#   scripts/flake-input-impact.sh [--flake DIR] [--os linux|darwin|auto] --base-fingerprint
#
# DIR defaults to the git toplevel of the cwd. <input> must be a key of
# `.nodes.root.inputs` in DIR/flake.lock.
#
# DARWIN IS NEVER CLASSIFIED FROM LINUX, AND VICE VERSA.
#
# This script evaluates `nixosConfigurations` only when `builtins.
# currentSystem` is a Linux system, and `darwinConfigurations` only when it
# is a Darwin system -- each machine fingerprints its own OS's
# configurations (plus devShells/packages for its own system) and nothing
# else. `--os` lets a caller (CI) say which half it expects to run and
# fail loudly on a mismatch, rather than silently evaluating the wrong (or
# no) half.
#
# This is deliberate, not merely cautious: evaluating Darwin configs from
# Linux depends on Import-From-Derivation (catppuccin ports importTOML/
# importYAML their sources) landing on a build, and on Linux those
# aarch64-darwin derivations can only ever be *substituted* -- so the eval
# fails with "platform mismatch" the moment the exact build isn't already
# sitting in a cache, which is not a property this script can rely on.
# ci-darwin.yaml's `find-darwin` job already runs on the self-hosted macOS
# pool for exactly this reason (commit 2a3b120a, "ci(darwin): run
# find-darwin on the self-hosted macOS pool"; see also b2990aba), and this
# script follows the same split: the watch Action classifies the Darwin
# half there, never on a Linux runner. See also scripts/impacted-hosts.sh's
# own comment on the same IFD issue (NixOS/nix#5410 is the general class of
# bug upstream, and GitHub issue #2684 in this repo).
#
# Output:
#   Plain mode (default): exactly one word on stdout -- "none", "rebuild"
#   or "source" -- with all progress/reasons on stderr.
#   --json: {"input": ..., "kind": ..., "rev": <the bumped revision that was
#   classified, or null for a lock type without one>, "changed": [<attrs
#   whose outPath differs between base and new>]} on stdout. `rev` lets a
#   caller confirm it classified the upstream revision it meant to (upstream
#   can move between deciding to classify and running this).
#
#   --base-fingerprint: one sha256 of the base fingerprint alone (what the
#   flake builds on this OS with its lock as is), no <input>. The watch
#   Action reuses a cached classification only while this is unchanged.
#
# Exit codes: 0 on any successful classification (including "none"); 2 on
# a usage/validation error (unknown input, wrong --os for this machine);
# 1 on an evaluation failure.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/flake-input-impact.sh [--flake DIR] [--os linux|darwin|auto] [--json] <input>
       scripts/flake-input-impact.sh [--flake DIR] [--os linux|darwin|auto] --base-fingerprint
EOF
}

FLAKE_DIR=""
JSON=0
BASE_ONLY=0
OS_ARG="auto"
INPUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --flake)
      [[ $# -ge 2 ]] || {
        echo "ERROR: --flake requires a value" >&2
        exit 2
      }
      FLAKE_DIR="$2"
      shift 2
      ;;
    --flake=*)
      FLAKE_DIR="${1#--flake=}"
      shift
      ;;
    --os)
      [[ $# -ge 2 ]] || {
        echo "ERROR: --os requires a value (linux, darwin or auto)" >&2
        exit 2
      }
      OS_ARG="$2"
      shift 2
      ;;
    --os=*)
      OS_ARG="${1#--os=}"
      shift
      ;;
    --json)
      JSON=1
      shift
      ;;
    --base-fingerprint)
      BASE_ONLY=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      echo "ERROR: unknown flag $1" >&2
      usage
      exit 2
      ;;
    *)
      if [[ -n "$INPUT" ]]; then
        echo "ERROR: input given twice ($INPUT, $1)" >&2
        exit 2
      fi
      INPUT="$1"
      shift
      ;;
  esac
done

if [[ $BASE_ONLY -eq 1 && -n "$INPUT" ]]; then
  echo "ERROR: --base-fingerprint takes no <input>" >&2
  usage
  exit 2
fi
if [[ $BASE_ONLY -eq 0 && -z "$INPUT" ]]; then
  echo "ERROR: missing <input>" >&2
  usage
  exit 2
fi

case "$OS_ARG" in
  linux | darwin | auto) ;;
  *)
    echo "ERROR: --os must be linux, darwin or auto (got: $OS_ARG)" >&2
    exit 2
    ;;
esac

if [[ -z "$FLAKE_DIR" ]]; then
  FLAKE_DIR="$(git rev-parse --show-toplevel)"
fi
FLAKE_DIR="$(cd "$FLAKE_DIR" && pwd)"

if [[ ! -f "$FLAKE_DIR/flake.lock" ]]; then
  echo "ERROR: $FLAKE_DIR/flake.lock not found" >&2
  exit 2
fi

# Resolved to its physical path: on macOS mktemp's directory is under /tmp
# or /var, both symlinks into /private, and Nix refuses a --reference-lock-
# file whose path goes through a symlink ("path '/tmp' is a symlink"), which
# failed every Darwin classification.
#
# Two steps, each checked: if mktemp failed, `cd ""` would succeed in the
# current directory, and the trap below would then rm -rf the working tree.
TMP_RAW="$(mktemp -d)" || {
  echo "ERROR: mktemp -d failed" >&2
  exit 1
}
TMP="$(cd "$TMP_RAW" && pwd -P)" || {
  echo "ERROR: cannot resolve $TMP_RAW" >&2
  rmdir "$TMP_RAW" 2>/dev/null || true
  exit 1
}
trap 'rm -rf "$TMP"' EXIT

# Explicit rather than relying on nix.conf: the pre-commit hook entry below
# runs this script inside a Nix build sandbox (see flake/dev/checks.nix),
# which starts from a clean nix.conf that does not inherit the host's
# `experimental-features = nix-command flakes` (set in
# modules/base/system.nix) -- confirmed empirically, see this subtask's
# verification notes. Harmless and redundant everywhere else.
NIX_FEATURES=(--extra-experimental-features "nix-command flakes")

CURRENT_SYSTEM="$(nix "${NIX_FEATURES[@]}" eval --impure --raw --expr 'builtins.currentSystem' 2>"$TMP/err")" || {
  echo "ERROR: failed to read builtins.currentSystem:" >&2
  cat "$TMP/err" >&2
  exit 1
}
case "$CURRENT_SYSTEM" in
  *-darwin) HOST_OS="darwin" ;;
  *-linux) HOST_OS="linux" ;;
  *)
    echo "ERROR: unrecognised system '$CURRENT_SYSTEM'" >&2
    exit 1
    ;;
esac

if [[ "$OS_ARG" == "auto" ]]; then
  OS="$HOST_OS"
else
  OS="$OS_ARG"
  if [[ "$OS" != "$HOST_OS" ]]; then
    printf 'ERROR: --os %s requested, but this machine is %s (%s).\n' "$OS_ARG" "$HOST_OS" "$CURRENT_SYSTEM" >&2
    printf '       Darwin configurations are evaluated on the macOS pool only, never on Linux,\n' >&2
    printf '       and vice versa. Run this on a runner of the matching OS.\n' >&2
    exit 2
  fi
fi

case "$OS" in
  linux) CFG_ATTR="nixosConfigurations" ;;
  darwin) CFG_ATTR="darwinConfigurations" ;;
esac

# ---------------------------------------------------------------------------
# Output fingerprints (used below, and alone by --base-fingerprint).
# ---------------------------------------------------------------------------

# These are Nix expressions (single-quoted deliberately: `${...}` below is
# Nix string interpolation, not shell), passed verbatim to `nix eval
# --apply`.
NIXOS_APPLY='cfgs: builtins.mapAttrs (_: c: c.config.system.build.toplevel.outPath) cfgs'
# shellcheck disable=SC2016
DEVSHELLS_APPLY='ds: let sys = builtins.currentSystem; in
  if (ds ? ${sys}) && (ds.${sys} ? default) then { default = ds.${sys}.default.outPath; } else { }'
# shellcheck disable=SC2016
PACKAGES_APPLY='ps: let sys = builtins.currentSystem; in
  if ps ? ${sys} then builtins.mapAttrs (_: p: p.outPath) ps.${sys} else { }'

# Evaluates one attribute family of $FLAKE_DIR with the given extra nix-eval
# flags (lock override machinery). A flake that simply has no top-level
# `packages`/`devShells` (or no CFG_ATTR, e.g. a host-only repo with no
# darwinConfigurations) contributes {} to the fingerprint. Any OTHER failure
# -- a fetch error, or the bumped input breaking evaluation -- is fatal:
# swallowing it would let both fingerprints come out empty and classify a
# real change as "none", so no PR would ever be opened for it.
# True only for Nix's own top-level "this flake has no such output"
# diagnostic: a single `error: flake '...' does not provide attribute ...
# or '<attr>'` line with no evaluation trace. The same words inside a real
# evaluation error (e.g. a thrown message, or a bumped dependency dropping an
# attribute an existing output still uses) come with `… while ...` trace
# lines, and must stay fatal.
missing_output() { # attr stderr-file
  local attr="$1" err="$2" first
  first="$(grep -m1 '^error:' "$err" || true)"
  [[ "$first" =~ ^error:\ flake\ \'[^\']*\'\ does\ not\ provide\ attribute\ .*\'${attr}\'$ ]] &&
    ! grep -q '… while' "$err"
}

eval_family() {
  local attr="$1"
  local apply="$2"
  shift 2
  local out
  if out="$(nix "${NIX_FEATURES[@]}" eval --json --impure "$@" "$FLAKE_DIR#${attr}" --apply "$apply" 2>"$TMP/family.err")"; then
    printf '%s' "$out"
  elif missing_output "$attr" "$TMP/family.err"; then
    echo "  (no $attr output; treated as empty)" >&2
    printf '{}'
  else
    echo "ERROR: evaluating $attr failed:" >&2
    tail -n 30 "$TMP/family.err" >&2
    exit 1
  fi
}

# Builds one fingerprint object, prefixing each family's keys so the three
# families can never collide: {"nixosConfigurations.<h>": outPath, ...,
# "devShells.<system>.default": outPath, "packages.<system>.<p>": outPath}.
fingerprint() {
  local label="$1"
  shift
  echo "==> evaluating fingerprint: $label" >&2
  local cfgs_json devshells_json packages_json
  # `|| exit 1` on each: bash does not carry `set -e` into $(...), so an
  # eval_family failure would otherwise be ignored here.
  cfgs_json="$(eval_family "$CFG_ATTR" "$NIXOS_APPLY" "$@")" || exit 1
  devshells_json="$(eval_family "devShells" "$DEVSHELLS_APPLY" "$@")" || exit 1
  packages_json="$(eval_family "packages" "$PACKAGES_APPLY" "$@")" || exit 1
  jq -cn \
    --arg cfgAttr "$CFG_ATTR" \
    --arg sys "$CURRENT_SYSTEM" \
    --argjson cfgs "$cfgs_json" \
    --argjson devshells "$devshells_json" \
    --argjson packages "$packages_json" '
    ($cfgs | to_entries | map({key: ($cfgAttr + "." + .key), value: .value})) as $c |
    ($devshells | to_entries | map({key: ("devShells." + $sys + "." + .key), value: .value})) as $d |
    ($packages | to_entries | map({key: ("packages." + $sys + "." + .key), value: .value})) as $p |
    ($c + $d + $p) | from_entries
  '
}

diff_keys() {
  # Attribute paths whose outPath differs (or appeared/disappeared)
  # between two fingerprint objects.
  jq -cn --argjson old "$1" --argjson new "$2" '
    ($old | keys) + ($new | keys) | unique | map(select(($old[.] // null) != ($new[.] // null)))
  '
}

if [[ $BASE_ONLY -eq 1 ]]; then
  # One hash of what this flake builds on this OS as it stands: a cached
  # classification is valid only while this is unchanged, because a change to
  # our own config can change what bumping an input would do.
  BASE_FP="$(fingerprint "base (on-disk flake.lock)" --no-update-lock-file)" || exit 1
  jq -cS . <<<"$BASE_FP" | sha256sum | cut -d' ' -f1
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. Validate the input is a real root input.
# ---------------------------------------------------------------------------

ROOT_INPUTS_JSON="$(jq -c '.nodes.root.inputs // {}' "$FLAKE_DIR/flake.lock")"
NODE_NAME="$(jq -r --arg i "$INPUT" '.[$i] // empty' <<<"$ROOT_INPUTS_JSON")"
if [[ -z "$NODE_NAME" ]]; then
  printf 'ERROR: %q is not a root input in %s/flake.lock\n' "$INPUT" "$FLAKE_DIR" >&2
  exit 2
fi

echo "input: $INPUT (lock node: $NODE_NAME)  flake: $FLAKE_DIR  os: $OS" >&2

# ---------------------------------------------------------------------------
# 2. Bump the input in a scratch lock file; short-circuit if it didn't move.
# ---------------------------------------------------------------------------

echo "==> nix flake update $INPUT (scratch lock, not touching flake.lock)" >&2
if ! nix "${NIX_FEATURES[@]}" flake update "$INPUT" --flake "$FLAKE_DIR" --output-lock-file "$TMP/new.lock" --impure \
  >"$TMP/update.out" 2>"$TMP/update.err"; then
  echo "ERROR: nix flake update $INPUT failed:" >&2
  tail -n 30 "$TMP/update.err" >&2
  exit 1
fi
cat "$TMP/update.err" >&2

old_node_locked() { jq -c --arg n "$NODE_NAME" '.nodes[$n].locked' "$FLAKE_DIR/flake.lock"; }
new_node_locked() { jq -c --arg n "$NODE_NAME" '.nodes[$n].locked' "$TMP/new.lock"; }

OLD_LOCKED="$(old_node_locked)"
NEW_LOCKED="$(new_node_locked)"

node_moved() {
  # Compares the two `locked` objects on `rev` when both have one
  # (git/github-ish), else on `narHash` (tarball, path, and anything else).
  jq -n --argjson old "$OLD_LOCKED" --argjson new "$NEW_LOCKED" '
    (if ($old | has("rev")) and ($new | has("rev")) then
       ($old.rev != $new.rev)
     else
       ($old.narHash != $new.narHash)
     end)
  '
}

emit() {
  local kind="$1"
  shift
  local changed_json="${1:-[]}"
  if [[ $JSON -eq 1 ]]; then
    jq -cn --arg input "$INPUT" --arg kind "$kind" --argjson changed "$changed_json" \
      --argjson new "$NEW_LOCKED" \
      '{input: $input, kind: $kind, rev: ($new.rev // null), changed: $changed}'
  else
    printf '%s\n' "$kind"
  fi
  exit 0
}

if [[ "$(node_moved)" != "true" ]]; then
  echo "reason: upstream has not moved (locked rev/narHash unchanged)" >&2
  emit "none"
fi

# ---------------------------------------------------------------------------
# 3. Output fingerprints: base (on-disk lock) vs. new (scratch lock).
# ---------------------------------------------------------------------------

# --no-update-lock-file: the baseline is the on-disk lock exactly. If
# flake.nix and flake.lock disagree, fail rather than let nix re-resolve
# (and rewrite) the real lock and fingerprint something else.
BASE_FP="$(fingerprint "base (on-disk flake.lock)" --no-update-lock-file)" || exit 1
NEW_FP="$(fingerprint "new (scratch lock, $INPUT bumped)" --reference-lock-file "$TMP/new.lock" --no-write-lock-file)" || exit 1

CHANGED="$(diff_keys "$BASE_FP" "$NEW_FP")"
if [[ "$(jq 'length' <<<"$CHANGED")" -eq 0 ]]; then
  echo "reason: no nixosConfigurations/darwinConfigurations/devShells/packages outPath changed" >&2
  emit "none" "$CHANGED"
fi
echo "changed: $(jq -c . <<<"$CHANGED")" >&2

# ---------------------------------------------------------------------------
# 4. Owned-nixpkgs test: does holding the input's own nixpkgs at its old
#    revision (while everything else about the input is the new lock)
#    restore the base fingerprint?
# ---------------------------------------------------------------------------

OWN_NIXPKGS_NODE="$(jq -r --arg n "$NODE_NAME" '.nodes[$n].inputs.nixpkgs // empty' "$FLAKE_DIR/flake.lock")"
OWN_NIXPKGS_IS_STRING="$(jq -r --arg n "$NODE_NAME" '(.nodes[$n].inputs.nixpkgs // null) | type == "string"' "$FLAKE_DIR/flake.lock")"

if [[ "$OWN_NIXPKGS_IS_STRING" != "true" ]]; then
  echo "reason: $INPUT does not own its own nixpkgs (follows ours, or has none)" >&2
  emit "source" "$CHANGED"
fi

OLD_NIXPKGS_LOCKED="$(jq -c --arg n "$OWN_NIXPKGS_NODE" '.nodes[$n].locked' "$FLAKE_DIR/flake.lock")"
OLD_NIXPKGS_TYPE="$(jq -r '.type' <<<"$OLD_NIXPKGS_LOCKED")"

OLD_NIXPKGS_REF=""
case "$OLD_NIXPKGS_TYPE" in
  github)
    OLD_NIXPKGS_REF="github:$(jq -r '.owner' <<<"$OLD_NIXPKGS_LOCKED")/$(jq -r '.repo' <<<"$OLD_NIXPKGS_LOCKED")/$(jq -r '.rev' <<<"$OLD_NIXPKGS_LOCKED")"
    ;;
  tarball)
    OLD_NIXPKGS_REF="$(jq -r '.url' <<<"$OLD_NIXPKGS_LOCKED")"
    ;;
  *)
    echo "reason: $INPUT owns a nixpkgs of type '$OLD_NIXPKGS_TYPE' (not github/tarball); cannot pin it back, classifying by the raw diff" >&2
    emit "source" "$CHANGED"
    ;;
esac

echo "==> rebuild test: hold $INPUT/nixpkgs at $OLD_NIXPKGS_REF" >&2
OVERRIDE_FP="$(fingerprint "override ($INPUT/nixpkgs pinned old)" \
  --reference-lock-file "$TMP/new.lock" --no-write-lock-file \
  --override-input "$INPUT/nixpkgs" "$OLD_NIXPKGS_REF")" || exit 1

OVERRIDE_CHANGED="$(diff_keys "$BASE_FP" "$OVERRIDE_FP")"
if [[ "$(jq 'length' <<<"$OVERRIDE_CHANGED")" -eq 0 ]]; then
  echo "reason: holding $INPUT's own nixpkgs at its old revision restores the base fingerprint" >&2
  emit "rebuild" "$CHANGED"
else
  echo "reason: $INPUT still changes outputs with its own nixpkgs held at its old revision" >&2
  emit "source" "$CHANGED"
fi
