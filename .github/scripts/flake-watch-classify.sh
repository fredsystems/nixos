#!/usr/bin/env bash
# .github/scripts/flake-watch-classify.sh OS
#
# flake-input-watch.yaml's classify step: runs scripts/flake-input-impact.sh
# for every entry of $INPUTS (the plan's classify list for this OS:
# [{"input", "upstream_rev", ...}]) on this runner's OS and writes
# impact-OS.json, {"<input>": "none|rebuild|source"}.
#
# A result is kept only if the classifier bumped the input to exactly the
# planned upstream_rev. Upstream can move between planning and running this,
# and a result recorded under revisions it was not computed for would be
# reused as if it were; a mismatch is dropped and asked again next hour.
#
# One input failing to evaluate does not lose the others: the file always
# holds every successful classification, and the step fails at the end (so
# the run shows red) only after writing it. The Publish step then records
# what did succeed; a failed input is simply asked again next hour.
set -euo pipefail

OS="${1:?usage: flake-watch-classify.sh linux|darwin}"
OUT="impact-$OS.json"
: "${INPUTS:?INPUTS must be the JSON classify list from the plan}"

# jq (and, on macOS, bash 4+) come from the workflow's "Tools from the
# flake's nixpkgs" step.
echo '{}' >"$OUT"
failed=()
while IFS=$'\t' read -r input planned; do
  [[ -n "$input" ]] || continue
  echo "::group::$input ($OS)"
  if result="$(scripts/flake-input-impact.sh --os "$OS" --json "$input")"; then
    kind="$(jq -r .kind <<<"$result")"
    rev="$(jq -r '.rev // ""' <<<"$result")"
    if [[ "$rev" == "$planned" ]]; then
      echo "$input: $kind"
      jq --arg i "$input" --arg k "$kind" '. + {($i): $k}' "$OUT" >"$OUT.tmp"
      mv "$OUT.tmp" "$OUT"
    else
      echo "::warning title=flake-watch::$input moved again since planning (planned $planned, classified ${rev:-?}); asking again next hour"
    fi
  else
    failed+=("$input")
  fi
  echo "::endgroup::"
done < <(jq -r '.[] | [.input, .upstream_rev] | @tsv' <<<"$INPUTS")

jq -S . "$OUT"
if [[ ${#failed[@]} -gt 0 ]]; then
  echo "::error title=flake-watch::could not classify on $OS: ${failed[*]}" >&2
  exit 1
fi
