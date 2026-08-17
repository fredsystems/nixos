#!/usr/bin/env bash
#
# check-opencode-jsonc.sh -- validate opencode.jsonc against opencode's own
# config JSON Schema, plus a hermetic structural check that stands in for
# the schema when no network is available.
#
# WHY THIS EXISTS
#
# opencode.jsonc:1 declares `"$schema": "https://opencode.ai/config.json"`,
# but nothing validated against it. opencode's `Config` schema sets
# `additionalProperties: false`, so ANY unknown top-level key -- a typo, a
# key from a newer opencode version this repo hasn't updated docs for, a
# copy-paste mistake -- produces a hard `ConfigInvalidError` and NO config
# loads at all: not "that one key is ignored", the whole file fails
# closed and silently. That exact failure mode happened and is what opened
# this audit. The pre-existing pre-commit stack runs `check-jsonschema`
# twice already (`--builtin-schema github-actions` / `github-workflows`),
# but its generic `check-json` hook only matches `\.json$`, so a `.jsonc`
# file was never in scope for any of it.
#
# TWO VALIDATION MODES, ONE SCRIPT
#
# 1. Full schema validation (default; network required). Fetches opencode's
#    live schema from https://opencode.ai/config.json and validates the
#    (comment-stripped) config against it with check-jsonschema. This is
#    the real, complete, always-current check. It is NOT wired into either
#    the pre-commit hook or the standalone `checks.opencode-jsonc-schema`
#    flake check, and this is a harder constraint than "sandboxed Nix
#    builds have no network": this repo's repo-local hooks are wired
#    through git-hooks.nix, and git-hooks' own `run` derivation -- what
#    `nix build .#checks.pre-commit-check` and CI's lint job both exercise
#    -- runs the ENTIRE hook suite (real `pre-commit run --all-files`)
#    inside ONE sandboxed Nix build with no network and the nix-command
#    feature disabled. That is true regardless of whether a human
#    triggers it via `git commit` (which happens to reuse the exact same
#    generated `.pre-commit-config.yaml`) or CI triggers it via `nix flake
#    check`. So a hook needing network here does not fail gracefully in
#    just the sandboxed path and succeed for real commits -- it hard-fails
#    the whole hook suite for everyone, every time. Verified empirically:
#    wiring this mode into the hook broke `nix build
#    .#checks.pre-commit-check` with a DNS-resolution error.
#    This mode is for manual/ad-hoc use: run it yourself when you touch
#    opencode.jsonc and want the real, complete answer.
#
# 2. Structural check (`--offline`; hermetic, no network; the mode wired
#    into both the hook and the standalone flake check). Re-derives, by
#    hand, the two specific invariants that bit before, straight from a
#    dated snapshot of opencode's schema, rather than vendoring the whole
#    schema document (a multi-hundred-line file that would silently go
#    stale exactly like MODULES.md did -- vendoring a schema to catch drift
#    is itself a drift surface):
#      - the top-level key set is `additionalProperties: false`, so every
#        key in opencode.jsonc must be in the known-good list below
#      - every entry under `command` requires a `template` field
#    This is deliberately a small, human-reviewed allowlist rather than a
#    full schema copy: it changes only when a human intentionally adds a
#    new top-level key to opencode.jsonc, at which point extending a
#    ~30-entry array in the same commit is a reasonable ask -- unlike
#    keeping a nested multi-hundred-line JSON Schema document in sync with
#    upstream on every opencode release.
#
# Usage:
#   scripts/check-opencode-jsonc.sh            # full schema check (network, manual only)
#   scripts/check-opencode-jsonc.sh --offline  # structural check (hook + flake check)
set -euo pipefail

# Located by BASH_SOURCE, not `git rev-parse`, so this also works from
# inside the standalone flake check's sandboxed build (no .git there).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CONFIG_FILE="opencode.jsonc"
SCHEMA_URL="https://opencode.ai/config.json"

OFFLINE=0
for arg in "$@"; do
  case "$arg" in
    --offline) OFFLINE=1 ;;
    *)
      echo "error: unknown argument '$arg'" >&2
      exit 1
      ;;
  esac
done

if [[ ! -f $CONFIG_FILE ]]; then
  echo "error: $CONFIG_FILE not found (run from the repository root)" >&2
  exit 1
fi

# Snapshot of opencode's `$defs.Config.properties` keys from
# https://opencode.ai/config.json, taken 2026-08-17 against the opencode
# version pinned in overlays/opencode.nix (1.18.18). Re-sync this list (and
# bump the date) whenever overlays/opencode.nix's `version` is bumped AND
# a legitimate new top-level key is intentionally added to opencode.jsonc.
# shellcheck disable=SC2016 # '$schema' is a literal array element, not shell interpolation
KNOWN_TOP_LEVEL_KEYS=(
  '$schema' agent attachment autoshare autoupdate command compaction
  default_agent disabled_providers enabled_providers enterprise experimental
  formatter instructions layout logLevel lsp mcp mode model permission plugin
  provider reference references server share shell skills small_model
  snapshot subagent_depth tool_output tools username watcher
)

# Fail on a missing dependency with an actionable message. This is separate
# from the parse check below and MUST stay separate: conflating "the parser
# is unavailable" with "the file is invalid" reports a config bug that does
# not exist, which is the exact false-signal class this check was added to
# prevent. The flake check and pre-commit hook supply these via
# runtimeInputs; a human running this bare needs `nix develop`.
command -v python3 >/dev/null 2>&1 || {
  echo "error: required tool not on PATH: python3" >&2
  echo "hint: run inside 'nix develop', or via 'nix build .#checks.\${system}.opencode-jsonc-schema'" >&2
  exit 1
}

if ! python3 -c 'import json5' 2>/dev/null; then
  echo "error: the python 'json5' module is not available" >&2
  echo "note: this is a MISSING DEPENDENCY, not a problem with $CONFIG_FILE" >&2
  echo "hint: run inside 'nix develop', or via 'nix build .#checks.\${system}.opencode-jsonc-schema'" >&2
  exit 1
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

canonical_json="${workdir}/opencode.json"

# opencode.jsonc is JSONC (line comments, trailing commas), which no
# strict JSON parser (jq, python's json, check-jsonschema's own loader)
# accepts. json5 is a superset of JSONC and round-trips it to canonical
# JSON losslessly for schema-checking purposes.
if ! python3 -c '
import json, sys
import json5

with open(sys.argv[1]) as f:
    data = json5.load(f)

with open(sys.argv[2], "w") as f:
    json.dump(data, f)
' "$CONFIG_FILE" "$canonical_json" 2>"${workdir}/parse-error.log"; then
  echo "error: $CONFIG_FILE is not valid JSONC (failed to parse)" >&2
  echo "" >&2
  cat "${workdir}/parse-error.log" >&2
  exit 1
fi

errors=()

# --- structural check: additionalProperties: false emulation --------------

mapfile -t actual_keys < <(jq -r 'keys[]' "$canonical_json" | sort -u)
mapfile -t unknown_keys < <(comm -23 \
  <(printf '%s\n' "${actual_keys[@]}") \
  <(printf '%s\n' "${KNOWN_TOP_LEVEL_KEYS[@]}" | sort -u))

for k in "${unknown_keys[@]}"; do
  [[ -n $k ]] && errors+=(
    "${CONFIG_FILE}: unknown top-level key '${k}' -- opencode's Config schema sets additionalProperties: false, so this key alone makes the ENTIRE config fail to load (ConfigInvalidError). Remove it, fix the typo, or add it to KNOWN_TOP_LEVEL_KEYS in $(basename "$0") if it is a legitimately new opencode option."
  )
done

# --- structural check: every `command.*` entry requires `template` -------

# This must FAIL CLOSED, and getting that right takes more than the obvious
# one-liner. Two traps:
#
#   1. `mapfile < <(jq ...)` does NOT propagate the process substitution's
#      exit status, and `set -e` does not catch it either -- mapfile returns
#      0 regardless. So a jq error yields an EMPTY array, which reads as
#      "no commands are missing a template" and PASSES.
#   2. If `command` or any entry under it is a scalar rather than an object,
#      `.value.template` makes jq error ("Cannot index string with string")
#      and exit 5 -- hitting trap 1 above.
#
# Combined, a config like {"command": {"foo": "bar"}} would have been
# reported as valid by a check whose whole purpose is to reject it. So:
# validate the shapes first, and capture jq's status explicitly rather than
# through a pipeline that discards it.

command_type="$(jq -r 'if has("command") then (.command | type) else "absent" end' "$canonical_json")"
command_count=0

case "$command_type" in
  absent | 'null') ;; # no `command` block at all is fine
  object)
    command_count="$(jq -r '.command | length' "$canonical_json")"

    # Reject non-object entries explicitly, before anything indexes into them.
    mapfile -t non_object_commands < <(
      jq -r '.command | to_entries[] | select((.value | type) != "object") | "\(.key) (\(.value | type))"' \
        "$canonical_json"
    )
    for c in "${non_object_commands[@]}"; do
      [[ -n $c ]] && errors+=(
        "${CONFIG_FILE}: command '${c%% *}' is a ${c#* }, not an object -- opencode's schema requires each command entry to be an object with a 'template' field."
      )
    done

    # Only now is it safe to read .template. Capture jq's status via a temp
    # file rather than process substitution, so a failure is actually seen.
    if ! jq -r '.command | to_entries[] | select((.value | type) == "object") | select(.value.template == null) | .key' \
      "$canonical_json" >"${workdir}/missing-template.txt" 2>"${workdir}/missing-template.err"; then
      echo "error: failed to inspect 'command' entries in $CONFIG_FILE" >&2
      cat "${workdir}/missing-template.err" >&2
      exit 1
    fi
    while IFS= read -r c; do
      [[ -n $c ]] && errors+=(
        "${CONFIG_FILE}: command '${c}' has no 'template' field, which opencode's schema requires for every command entry."
      )
    done <"${workdir}/missing-template.txt"
    ;;
  *)
    errors+=(
      "${CONFIG_FILE}: top-level 'command' is a ${command_type}, not an object -- opencode's schema expects a map of command name to command object."
    )
    ;;
esac

if [[ ${#errors[@]} -gt 0 ]]; then
  echo "opencode.jsonc structural check FAILED:" >&2
  echo "" >&2
  for e in "${errors[@]}"; do
    echo "  - ${e}" >&2
  done
  exit 1
fi

echo "opencode.jsonc structural check OK (${#actual_keys[@]} top-level keys, ${command_count} command entr$([[ $command_count -eq 1 ]] && echo y || echo ies) validated)"

if [[ $OFFLINE -eq 1 ]]; then
  exit 0
fi

# --- full schema validation (network) -------------------------------------

echo "==> validating against live schema: ${SCHEMA_URL}"
check-jsonschema --schemafile "$SCHEMA_URL" "$canonical_json"
