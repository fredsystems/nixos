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
# Usage:
#   scripts/impacted-hosts.sh --os linux|darwin [BASE_REF] [options]
#
#   BASE_REF defaults to origin/main. CI passes the PR/merge_group base
#   sha explicitly.
#
# Options:
#   --json              machine-readable {"mode": "...", "hosts": [...]}
#   --eval              also `nix eval` each resulting host's drvPath
#   --committed-only    diff BASE_REF...HEAD only; skip the working-tree
#                       union (see below). CI always wants this implicitly
#                       true in effect since its checkout is clean, but a
#                       local dry run defaults to including uncommitted
#                       work so it answers "what would I be pushing".
#
# Output (default, human mode): the mode on stderr, then one host per
# line on stdout, or "no impacted hosts" on stderr if none. `--json` gives
# a single JSON object on stdout instead.
set -euo pipefail

OS=""
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

# Enumerate real hosts unconditionally -- needed either as the answer
# itself (FORCE_ALL) or to validate host-confined names. This is a pure
# `attrNames` call, not a per-host eval, so it's always cheap (well under
# a second).
NIX_EVAL_STDERR="$(mktemp)"
trap 'rm -f "$NIX_EVAL_STDERR"' EXIT
if ! ALL_HOSTS_JSON="$(nix eval ".#${FLAKE_ATTR}" --apply 'cfgs: builtins.attrNames cfgs' --json 2>"$NIX_EVAL_STDERR")"; then
  printf 'ERROR: failed to enumerate %s:\n%s\n' "$FLAKE_ATTR" "$(cat "$NIX_EVAL_STDERR")" >&2
  exit 1
fi
mapfile -t ALL_HOSTS < <(jq -r '.[]' <<<"$ALL_HOSTS_JSON")

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
  else
    # Host-confined: every non-inert changed path must live under this
    # OS's host directory, all under the same or different single-host
    # subdirectories -- collect the distinct set.
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
  echo "Running a real per-host derivation diff (base=${BASE_SHA})..." >&2
  if ! HEAD_JSON="$(nix eval --json ".#${FLAKE_ATTR}" --apply 'cfgs: builtins.mapAttrs (_: c: c.config.system.build.toplevel.outPath) cfgs' 2>"$NIX_EVAL_STDERR")"; then
    printf 'ERROR: failed to evaluate HEAD %s:\n%s\n' "$FLAKE_ATTR" "$(cat "$NIX_EVAL_STDERR")" >&2
    exit 1
  fi
  if ! BASE_JSON="$(nix eval --json "git+file://${REPO_ROOT}?rev=${BASE_SHA}#${FLAKE_ATTR}" --apply 'cfgs: builtins.mapAttrs (_: c: c.config.system.build.toplevel.outPath) cfgs' 2>"$NIX_EVAL_STDERR")"; then
    printf 'ERROR: failed to evaluate base rev %s %s:\n%s\n' "$BASE_SHA" "$FLAKE_ATTR" "$(cat "$NIX_EVAL_STDERR")" >&2
    exit 1
  fi
  mapfile -t HOSTS < <(jq -r -n --argjson old "$BASE_JSON" --argjson new "$HEAD_JSON" '
    $new | to_entries[] | select(($old[.key] // "") != .value) | .key
  ')
fi

if [[ $JSON -eq 1 ]]; then
  hosts_json=$(printf '%s\n' "${HOSTS[@]:-}" | jq -R . | jq -cs 'map(select(length > 0))')
  jq -cn --arg mode "$MODE" --argjson hosts "$hosts_json" '{mode: $mode, hosts: $hosts}'
else
  echo "mode: $MODE" >&2
  if [[ ${#HOSTS[@]} -eq 0 ]]; then
    echo "no impacted hosts" >&2
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
      nix eval ".#${FLAKE_ATTR}.${h}.config.system.build.toplevel.drvPath" >/dev/null
    done
  fi
  echo "[eval] OK" >&2
fi
