#!/usr/bin/env bash
# scripts/impacted-hosts.sh
#
# Given a base ref, print the nixosConfigurations/darwinConfigurations
# attribute names that a change actually impacts. This is the single
# source of truth for "which hosts need to be built" -- both
# .github/workflows/ci-linux.yaml and ci-darwin.yaml call this script
# directly (no separate inline classifier, no separate copy for local
# use), and the nixos-eval-impacted-hosts skill just runs it by hand.
#
# WHY THIS EXISTS (replacing a hand-maintained path-prefix classifier)
#
# The previous design guessed impact from a `case "$path"` statement --
# "modules/* means everyone", "hosts/linux/foo/* means foo" -- duplicated
# across ci-linux.yaml, ci-darwin.yaml, and a third mirror script, plus a
# hand-maintained flake-input-to-category table that had to agree across
# four files. That either over-built (safe but wasteful: a change that
# only reaches one host still rebuilt all ten) or, if a path shape wasn't
# anticipated, silently under-built.
#
# This script instead asks Nix the real question: did this host's
# `config.system.build.toplevel.outPath` actually change between base and
# HEAD? `.outPath` is derived from the derivation's hash and needs no
# realisation (no build) to compute, so a real answer for every host costs
# roughly a minute of pure evaluation (see scripts/gen-fleet-manifest.sh's
# header), not a build. Evaluating the base revision reuses this same git
# checkout via a `git+file://...?rev=<sha>` flake ref -- no worktree, no
# second clone.
#
# FOUR STEPS, IN ORDER OF INCREASING COST
#
# Each step either answers with confidence or falls through to the next,
# strictly safer step. The two "answer without a full eval" steps carry
# very different risk if their list is ever incomplete, which is why they
# are maintained differently:
#
#   1. FORCE_ALL_FILES (per OS): files that are read directly by the CI
#      pipeline itself -- workflow YAML, the composite action, the helper
#      scripts CI shells out to -- but are NOT part of the Nix evaluation
#      graph, so a derivation diff can never see a change to them. If any
#      changed file is in this list: every host, no eval needed. Getting
#      this list WRONG (missing an entry) is dangerous: a change to an
#      un-listed pipeline file could go completely unexercised by CI. It
#      is therefore not just documented but mechanically checked --
#      scripts/check-ci-pipeline-files-sync.sh parses ci-linux.yaml and
#      ci-darwin.yaml for every local script/action reference and fails
#      pre-commit if one is missing from the corresponding list below.
#
#   2. is_inert(): paths that are provably never read by any Nix
#      expression at all (docs, most of .github/, non-skill .opencode/
#      tooling files). If every changed file is inert: no hosts, no eval
#      needed. Getting this list WRONG (missing an entry, or being overly
#      conservative) only costs a missed optimisation -- an inert-looking
#      file that isn't on the list simply falls through to step 4, which
#      still gives the exactly correct answer, just slower. No mechanical
#      check needed; the failure mode has no correctness cost.
#
#   3. Host-confined: every remaining (non-inert) changed file lives under
#      hosts/<os>/<name>/, and every such <name> resolves to a real host
#      attribute. That set is the exact answer with certainty -- if
#      nothing outside a host's own directory changed, no other host's
#      closure could possibly be affected -- so skip the eval. Any name
#      that doesn't resolve (typo, brand-new host, unexpected shape) falls
#      through rather than guessing.
#
#   4. Real diff: evaluate every host's toplevel outPath at base and HEAD,
#      diff, report exactly the hosts that changed. Always correct;
#      always the fallback.
#
# DEV OUTPUTS (--target dev)
#
# The same question, asked of this machine's dev outputs instead of its
# hosts: every `devShells.<system>.*` and `packages.<system>.*` attribute,
# for <system> = builtins.currentSystem. CI's dev-shell jobs build and push
# exactly what this reports, so the dev shell (`nix develop`) and packages
# like `.#sbomnix` are cached whenever they actually change -- including
# through files nobody thought to list, such as overlays/default.nix.
#
# Steps 1, 2 and 4 apply unchanged (FORCE_ALL_FILES means every dev
# output; an all-inert change means none). Step 3 does NOT: a change
# confined to a host directory proves nothing about the dev outputs, so it
# falls through to the real diff (about ten seconds on this repo). The
# system is read from the machine, as
# the dev-shell jobs build it, so `--os` must match the machine's OS.
#
# Usage:
#   scripts/impacted-hosts.sh --os linux|darwin [BASE_REF] [options]
#
#   BASE_REF defaults to origin/main. CI passes the PR/merge_group base
#   sha explicitly.
#
# Options:
#   --target hosts|dev  what to diff (default: hosts). See DEV OUTPUTS.
#   --json              machine-readable {"mode": "...", "hosts": [...]};
#                       with --target dev, {"mode": "...", "outputs": [...]}
#                       where each output is a full attribute path such as
#                       "packages.x86_64-linux.sbomnix"
#   --eval              also `nix eval` each resulting host's (or output's)
#                       drvPath
#   --committed-only    diff BASE_REF...HEAD only; skip the working-tree
#                       union (see below). CI always wants this implicitly
#                       true in effect since its checkout is clean, but a
#                       local dry run defaults to including uncommitted
#                       work so it answers "what would I be pushing".
#
# Output (default, human mode): the mode on stderr, then one host (or
# output) per line on stdout, or "no impacted hosts" on stderr if none.
# `--json` gives a single JSON object on stdout instead.
set -euo pipefail

OS=""
TARGET="hosts"
BASE_REF=""
JSON=0
DO_EVAL=0
COMMITTED_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --os)
      if [[ $# -lt 2 ]]; then
        printf 'ERROR: --os requires a value (linux or darwin)\n' >&2
        exit 1
      fi
      OS="$2"
      shift 2
      ;;
    --os=*)
      OS="${1#--os=}"
      shift
      ;;
    --target)
      if [[ $# -lt 2 ]]; then
        printf 'ERROR: --target requires a value (hosts or dev)\n' >&2
        exit 1
      fi
      TARGET="$2"
      shift 2
      ;;
    --target=*)
      TARGET="${1#--target=}"
      shift
      ;;
    --json)
      JSON=1
      shift
      ;;
    --eval)
      DO_EVAL=1
      shift
      ;;
    --committed-only)
      COMMITTED_ONLY=1
      shift
      ;;
    -*)
      printf 'ERROR: unknown flag %q\n' "$1" >&2
      exit 1
      ;;
    *)
      if [[ -n "$BASE_REF" ]]; then
        printf 'ERROR: base ref given twice (%q, %q)\n' "$BASE_REF" "$1" >&2
        exit 1
      fi
      BASE_REF="$1"
      shift
      ;;
  esac
done

if [[ "$OS" != "linux" && "$OS" != "darwin" ]]; then
  printf 'ERROR: --os must be "linux" or "darwin" (got: %q)\n' "$OS" >&2
  exit 1
fi

if [[ "$TARGET" != "hosts" && "$TARGET" != "dev" ]]; then
  printf 'ERROR: --target must be "hosts" or "dev" (got: %q)\n' "$TARGET" >&2
  exit 1
fi

BASE_REF="${BASE_REF:-origin/main}"

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

case "$OS" in
  linux)
    FLAKE_ATTR="nixosConfigurations"
    HOST_DIR_PREFIX="hosts/linux/"
    CASE_FOLD=1
    # Kept in sync mechanically by check-ci-pipeline-files-sync.sh -- see
    # the nixos-ci-pipeline-file-sync skill.
    FORCE_ALL_FILES=(
      ".github/workflows/ci-linux.yaml"
      ".github/merge-queue-ci-skipper/action.yaml"
      "scripts/attic-push.sh"
      "scripts/check-colmena-parity.sh"
      "scripts/diff-closures-comment.sh"
      "scripts/impacted-hosts.sh"
    )
    ;;
  darwin)
    FLAKE_ATTR="darwinConfigurations"
    HOST_DIR_PREFIX="hosts/darwin/"
    CASE_FOLD=0
    FORCE_ALL_FILES=(
      ".github/workflows/ci-darwin.yaml"
      ".github/merge-queue-ci-skipper/action.yaml"
      "scripts/attic-push.sh"
      "scripts/impacted-hosts.sh"
    )
    ;;
esac

if ! git rev-parse --verify --quiet "${BASE_REF}^{commit}" >/dev/null 2>&1; then
  printf 'ERROR: base ref %q does not resolve to a commit.\n' "$BASE_REF" >&2
  exit 1
fi
BASE_SHA="$(git rev-parse "${BASE_REF}^{commit}")"

# Changed-path union. Committed history alone (`BASE_REF...HEAD`) misses
# uncommitted work, which reads identically to "nothing changed" -- the
# exact case this script exists to catch -- so a local dry run also unions
# staged, unstaged, and untracked paths by default. `--committed-only`
# skips that for a pure historical comparison.
CHANGED="$(
  {
    git diff --name-only "${BASE_REF}...HEAD"
    if [[ $COMMITTED_ONLY -eq 0 ]]; then
      git diff --cached --name-only
      git diff --name-only
      git ls-files --others --exclude-standard
    fi
  } | sort -u | grep -v '^$' || true
)"

UNTRACKED=""
if [[ $COMMITTED_ONLY -eq 0 ]]; then
  UNTRACKED="$(git ls-files --others --exclude-standard | grep -v '^$' || true)"
fi

CHANGED_COUNT=0
[[ -n "$CHANGED" ]] && CHANGED_COUNT="$(wc -l <<<"$CHANGED")"
printf 'os: %s  |  base: %s (%s)  |  changed paths: %s\n' \
  "$OS" "$BASE_REF" "$(git rev-parse --short "$BASE_REF")" "$CHANGED_COUNT" >&2

if [[ -n "$UNTRACKED" ]]; then
  {
    echo "WARNING: untracked files are INVISIBLE to nix eval (flakes read the git index):"
    while IFS= read -r u; do
      [[ -n "$u" ]] && printf '  %s\n' "$u"
    done <<<"$UNTRACKED"
    echo "         \`git add\` them first or any eval below evaluates a tree you did not write."
  } >&2
fi

is_inert() {
  local f="$1"
  case "$f" in
    # .opencode/skills/** feeds every Linux host's home-manager closure
    # via skillsSource (see features/ai/opencode/default.nix) but is a
    # no-op on darwin hosts today, and that could change per-host without
    # this script's knowledge. Never call it inert; let the real diff
    # (step 4) answer precisely and correctly for whichever hosts actually
    # import it, on either OS, forever -- no hardcoded assumption to rot.
    .opencode/skills/*) return 1 ;;
    .opencode/*) return 0 ;;
    # Anything else under .github/ that isn't in this OS's FORCE_ALL_FILES
    # (already checked before this function is ever consulted) plays no
    # part in either build pipeline.
    .github/*) return 0 ;;
    agents.md | README.md | MODULES.md | AUDIT-*.md | BACKUP-DESIGN.md | keymaps.md | hyprland.png | .dictionary.txt | typos.toml | .gitattributes | .envrc | opencode.jsonc)
      return 0
      ;;
    *) return 1 ;;
  esac
}

FORCE_ALL=0
if [[ -n "$CHANGED" ]]; then
  while IFS= read -r f; do
    for pf in "${FORCE_ALL_FILES[@]}"; do
      if [[ "$f" == "$pf" ]]; then
        FORCE_ALL=1
      fi
    done
  done <<<"$CHANGED"
fi

NIX_EVAL_STDERR="$(mktemp)"
trap 'rm -f "$NIX_EVAL_STDERR"' EXIT

# --target dev only: this machine's system, and every devShells/packages
# output for it. Prints one JSON object keyed by full attribute path
# ("packages.<system>.<name>"), each value being `fn` applied to that
# output. Both families are required to exist; a missing one is an error,
# not an empty set, so a broken eval can never read as "nothing changed".
SYSTEM=""
if [[ "$TARGET" == "dev" ]]; then
  if ! SYSTEM="$(nix eval --impure --raw --expr 'builtins.currentSystem' 2>"$NIX_EVAL_STDERR")"; then
    printf 'ERROR: failed to read builtins.currentSystem:\n%s\n' "$(cat "$NIX_EVAL_STDERR")" >&2
    exit 1
  fi
  if [[ "$SYSTEM" != *-"$OS" ]]; then
    printf 'ERROR: --target dev reports outputs for this machine (%s), which is not --os %s.\n' "$SYSTEM" "$OS" >&2
    exit 1
  fi
fi

dev_outputs_json() { # flake-ref nix-fn
  local ref="$1" fn="$2" fam out all='{}'
  for fam in devShells packages; do
    if ! out="$(nix eval --json "${ref}#${fam}" --apply "f: builtins.mapAttrs (_: ${fn}) (f.\"${SYSTEM}\" or { })" 2>"$NIX_EVAL_STDERR")"; then
      printf 'ERROR: failed to evaluate %s#%s:\n%s\n' "$ref" "$fam" "$(cat "$NIX_EVAL_STDERR")" >&2
      return 1
    fi
    all="$(jq -c --arg prefix "${fam}.${SYSTEM}." --argjson new "$out" \
      '. + ($new | with_entries(.key = $prefix + .key))' <<<"$all")"
  done
  printf '%s\n' "$all"
}

# Enumerate every target unconditionally -- needed either as the answer
# itself (FORCE_ALL) or to validate host-confined names. For --target dev
# ALL_HOSTS (and HOSTS below) hold output attribute paths, not hosts. Both
# are pure `attrNames`-style calls that force no derivation, so they're
# always cheap (well under a second).
if [[ "$TARGET" == "dev" ]]; then
  ALL_HOSTS_JSON="$(dev_outputs_json "." '_: null')" || exit 1
  mapfile -t ALL_HOSTS < <(jq -r 'keys[]' <<<"$ALL_HOSTS_JSON")
else
  if ! ALL_HOSTS_JSON="$(nix eval ".#${FLAKE_ATTR}" --apply 'cfgs: builtins.attrNames cfgs' --json 2>"$NIX_EVAL_STDERR")"; then
    printf 'ERROR: failed to enumerate %s:\n%s\n' "$FLAKE_ATTR" "$(cat "$NIX_EVAL_STDERR")" >&2
    exit 1
  fi
  mapfile -t ALL_HOSTS < <(jq -r '.[]' <<<"$ALL_HOSTS_JSON")
fi

MODE=""
HOSTS=()

if [[ $FORCE_ALL -eq 1 ]]; then
  MODE="force-all"
  HOSTS=("${ALL_HOSTS[@]}")
elif [[ -z "$CHANGED" ]]; then
  MODE="force-none"
  HOSTS=()
else
  ALL_INERT=1
  while IFS= read -r f; do
    if ! is_inert "$f"; then
      ALL_INERT=0
      break
    fi
  done <<<"$CHANGED"

  if [[ $ALL_INERT -eq 1 ]]; then
    MODE="force-none"
    HOSTS=()
  elif [[ "$TARGET" == "hosts" ]]; then
    # Host-confined: every non-inert changed path must live under this
    # OS's host directory, all under the same or different single-host
    # subdirectories -- collect the distinct set. Hosts only: a host
    # directory says nothing about the dev outputs (see DEV OUTPUTS).
    # Without this guard dev would still fall through, since no host name
    # matches an output path, but only by accident of naming.
    declare -A CONFINED_NAMES=()
    CONFINED_OK=1
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      is_inert "$f" && continue
      case "$f" in
        "${HOST_DIR_PREFIX}"*/*)
          name="${f#"$HOST_DIR_PREFIX"}"
          name="${name%%/*}"
          CONFINED_NAMES["$name"]=1
          ;;
        *)
          CONFINED_OK=0
          ;;
      esac
      [[ $CONFINED_OK -eq 0 ]] && break
    done <<<"$CHANGED"

    if [[ $CONFINED_OK -eq 1 && ${#CONFINED_NAMES[@]} -gt 0 ]]; then
      RESOLVED=()
      ALL_RESOLVED=1
      for name in "${!CONFINED_NAMES[@]}"; do
        match=""
        for h in "${ALL_HOSTS[@]}"; do
          if [[ $CASE_FOLD -eq 1 ]]; then
            if [[ "$(tr '[:upper:]' '[:lower:]' <<<"$h")" == "$(tr '[:upper:]' '[:lower:]' <<<"$name")" ]]; then
              match="$h"
              break
            fi
          else
            if [[ "$h" == "$name" ]]; then
              match="$h"
              break
            fi
          fi
        done
        if [[ -n "$match" ]]; then
          RESOLVED+=("$match")
        else
          ALL_RESOLVED=0
          break
        fi
      done
      if [[ $ALL_RESOLVED -eq 1 ]]; then
        MODE="host-confined"
        HOSTS=("${RESOLVED[@]}")
      fi
    fi
  fi
fi

if [[ -z "$MODE" ]]; then
  MODE="eval-diff"
  # `nix eval` only needs to *evaluate* the derivation graph and compute
  # .outPath from the .drv's hash, never *realize* (build) it, so in
  # principle --os darwin could run on any platform. The exception is
  # import-from-derivation (reading the *contents* of a built artifact
  # mid-eval): the Darwin home config hits IFD via catppuccin ports that
  # importTOML/importYAML their source. On a non-Darwin machine those
  # aarch64-darwin outputs can only be substituted, and the eval fails
  # with "platform mismatch" whenever catppuccin.cachix.org lacks the
  # exact build. That is why CI's find-darwin job runs on
  # [self-hosted, macOS], where they can simply be built. Running
  # --os darwin locally on Linux carries the same caveat.
  BASE_FLAKE="git+file://${REPO_ROOT}?rev=${BASE_SHA}"
  if [[ "$TARGET" == "dev" ]]; then
    echo "Running a real per-output derivation diff for ${SYSTEM} (base=${BASE_SHA})..." >&2
    HEAD_JSON="$(dev_outputs_json "." 'd: d.outPath')" || exit 1
    BASE_JSON="$(dev_outputs_json "$BASE_FLAKE" 'd: d.outPath')" || exit 1
  else
    echo "Running a real per-host derivation diff (base=${BASE_SHA})..." >&2
    if ! HEAD_JSON="$(nix eval --json ".#${FLAKE_ATTR}" --apply 'cfgs: builtins.mapAttrs (_: c: c.config.system.build.toplevel.outPath) cfgs' 2>"$NIX_EVAL_STDERR")"; then
      printf 'ERROR: failed to evaluate HEAD %s:\n%s\n' "$FLAKE_ATTR" "$(cat "$NIX_EVAL_STDERR")" >&2
      exit 1
    fi
    if ! BASE_JSON="$(nix eval --json "${BASE_FLAKE}#${FLAKE_ATTR}" --apply 'cfgs: builtins.mapAttrs (_: c: c.config.system.build.toplevel.outPath) cfgs' 2>"$NIX_EVAL_STDERR")"; then
      printf 'ERROR: failed to evaluate base rev %s %s:\n%s\n' "$BASE_SHA" "$FLAKE_ATTR" "$(cat "$NIX_EVAL_STDERR")" >&2
      exit 1
    fi
  fi
  mapfile -t HOSTS < <(jq -r -n --argjson old "$BASE_JSON" --argjson new "$HEAD_JSON" '
    $new | to_entries[] | select(($old[.key] // "") != .value) | .key
  ')
fi

if [[ $JSON -eq 1 ]]; then
  hosts_json=$(printf '%s\n' "${HOSTS[@]:-}" | jq -R . | jq -cs 'map(select(length > 0))')
  key="hosts"
  [[ "$TARGET" == "dev" ]] && key="outputs"
  jq -cn --arg mode "$MODE" --arg key "$key" --argjson hosts "$hosts_json" '{mode: $mode, ($key): $hosts}'
else
  echo "mode: $MODE" >&2
  if [[ ${#HOSTS[@]} -eq 0 ]]; then
    if [[ "$TARGET" == "dev" ]]; then
      echo "no impacted outputs" >&2
    else
      echo "no impacted hosts" >&2
    fi
  else
    printf '%s\n' "${HOSTS[@]}"
  fi
fi

if [[ $DO_EVAL -eq 1 ]]; then
  if [[ -n "$UNTRACKED" ]]; then
    echo "ERROR: refusing to --eval with untracked files present." >&2
    echo "       Nix flakes evaluate the git index, so the run would not" >&2
    echo "       include the files above and a PASS would be meaningless." >&2
    echo "       Run \`git add\` on them, then re-run. (\`--committed-only\`" >&2
    echo "       skips the working tree entirely if that is what you want.)" >&2
    exit 1
  fi
  echo "--- eval pass ---" >&2
  # Guarded by count rather than expanding "${HOSTS[@]}" directly: on Bash
  # older than 4.4, expanding an empty array under `set -u` (this script
  # runs with `set -euo pipefail`) is itself an unbound-variable error, so
  # a force-none/inert-only result would crash `--eval` instead of being
  # the legitimate no-op it is.
  if [[ ${#HOSTS[@]} -gt 0 ]]; then
    for h in "${HOSTS[@]}"; do
      echo "[eval] $h" >&2
      if [[ "$TARGET" == "dev" ]]; then
        nix eval ".#${h}.drvPath" >/dev/null
      else
        nix eval ".#${FLAKE_ATTR}.${h}.config.system.build.toplevel.drvPath" >/dev/null
      fi
    done
  fi
  echo "[eval] OK" >&2
fi
