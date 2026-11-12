#!/usr/bin/env bash
# scripts/check-flake-input-policy.sh
#
# Validates .github/flake-input-policy.json, the one place an input's update
# policy and maximum age live (agent-docs/plans/
# PLAN_03_FLAKE_INPUT_TRACKING.md, "Per-input policy lives in one file"):
#
#   - version is 1
#   - defaults.policy and every inputs.<name>.policy is "auto", "manual" or
#     "renovate" (updated only by Renovate; update-flakes.yaml never touches it)
#   - defaults.max_age_days and every inputs.<name>.max_age_days is a
#     positive integer
#   - no keys other than those (and "$comment")
#   - every input named exists in flake.lock's root inputs, so a renamed or
#     removed input cannot leave a policy that silently applies to nothing
#     (a "manual" entry for a stale name would let the real input auto-merge)
#
# Usage: scripts/check-flake-input-policy.sh [POLICY_FILE [LOCK_FILE]]
# Defaults: .github/flake-input-policy.json and flake.lock, relative to cwd.
set -euo pipefail

POLICY="${1:-.github/flake-input-policy.json}"
LOCK="${2:-flake.lock}"

for f in "$POLICY" "$LOCK"; do
  [[ -r "$f" ]] || {
    echo "ERROR: $f not found" >&2
    exit 2
  }
done

if ! jq -e . "$POLICY" >/dev/null 2>&1; then
  echo "ERROR: $POLICY is not valid JSON" >&2
  exit 1
fi

problems="$(jq -r --slurpfile lock "$LOCK" '
  def entry_problems($where):
    (if type != "object" then ["\($where): must be an object"] else
      ([keys[] | select(. != "policy" and . != "max_age_days" and . != "$comment")
        | "\($where): unknown key \(.)"])
      + (if has("policy") and (.policy | IN("auto", "manual", "renovate") | not)
           then ["\($where).policy: must be \"auto\", \"manual\" or \"renovate\", got \(.policy | tojson)"] else [] end)
      + (if has("max_age_days") and ((.max_age_days | type) != "number" or .max_age_days < 1 or (.max_age_days | floor) != .max_age_days)
           then ["\($where).max_age_days: must be a positive integer, got \(.max_age_days | tojson)"] else [] end)
    end);

  ($lock[0].nodes.root.inputs | keys) as $known
  | [ (if .version != 1 then "version: must be 1, got \(.version | tojson)" else empty end),
      ([keys[] | select(IN("version", "defaults", "inputs", "$comment") | not) | "unknown top-level key \(.)"][]),
      (if (.defaults | type) != "object" then "defaults: must be an object"
       else
         ((.defaults | entry_problems("defaults"))[]),
         (if (.defaults | has("policy") and has("max_age_days")) | not
            then "defaults: must set both policy and max_age_days" else empty end)
       end),
      (if (.inputs // {} | type) != "object" then "inputs: must be an object"
       else
         (.inputs // {} | to_entries[]
          | . as $e
          | ($e.value | entry_problems("inputs.\($e.key)"))[],
            (if ($e.key | IN($known[]) | not)
               then "inputs.\($e.key): not a root input in flake.lock" else empty end))
       end)
    ]
  | .[]
' "$POLICY")"

if [[ -n "$problems" ]]; then
  echo "ERROR: $POLICY is invalid:" >&2
  while IFS= read -r line; do
    printf '  - %s\n' "$line" >&2
  done <<<"$problems"
  exit 1
fi
echo "$POLICY: ok"
