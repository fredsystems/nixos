#!/usr/bin/env bash
# .github/scripts/flake-watch-classify.sh OS
#
# flake-input-watch.yaml's classify step: runs scripts/flake-input-impact.sh
# for every input in $INPUTS (a JSON array) on this runner's OS and writes
# impact-OS.json, {"<input>": "none|rebuild|source"}.
#
# One input failing to evaluate does not lose the others: the file always
# holds every successful classification, and the step fails at the end (so
# the run shows red) only after writing it. The publish job then records
# what did succeed; a failed input is simply asked again next hour.
set -euo pipefail

OS="${1:?usage: flake-watch-classify.sh linux|darwin}"
OUT="impact-$OS.json"
: "${INPUTS:?INPUTS must be a JSON array of input names}"

# Self-hosted runners have no jq on PATH; take it from the flake's own
# nixpkgs, as ci-linux.yaml's find-systems does.
if ! command -v jq >/dev/null 2>&1; then
  if ! bin_paths="$(nix build --no-link --print-out-paths --inputs-from . nixpkgs#jq)"; then
    echo "could not provision jq" >&2
    exit 1
  fi
  while IFS= read -r p; do
    [[ -n "$p" ]] && PATH="$p/bin:$PATH"
  done <<<"$bin_paths"
  export PATH
fi

echo '{}' >"$OUT"
failed=()
while IFS= read -r input; do
  [[ -n "$input" ]] || continue
  echo "::group::$input ($OS)"
  if kind="$(scripts/flake-input-impact.sh --os "$OS" "$input")"; then
    echo "$input: $kind"
    jq --arg i "$input" --arg k "$kind" '. + {($i): $k}' "$OUT" >"$OUT.tmp"
    mv "$OUT.tmp" "$OUT"
  else
    failed+=("$input")
  fi
  echo "::endgroup::"
done < <(jq -r '.[]' <<<"$INPUTS")

jq -S . "$OUT"
if [[ ${#failed[@]} -gt 0 ]]; then
  echo "::error title=flake-watch::could not classify on $OS: ${failed[*]}" >&2
  exit 1
fi
