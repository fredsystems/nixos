#!/usr/bin/env bash
#
# gen-fleet-manifest.sh -- publish the fleet deploy manifest.
#
# WHAT THIS IS
#
# For every host in `nixosConfigurations`, evaluate the store path of
# `config.system.build.toplevel` and record it. A host is up to date exactly
# when `readlink -f /run/current-system` equals the path recorded here. That
# comparison is the ground truth for "does this host need a deploy?", and it is
# the only formulation that is immune to all three ways the previous
# commit-counting check produced false alerts:
#
#   1. A host built from a dirty or branch checkout used to report "not behind"
#      because the recorded revision was the string "dirty" and the old script
#      hard-coded BEHIND=0 for that case. Here its running closure simply is
#      not one this manifest ever published, so it is reported as unmanaged.
#
#   2. A commit that moves main without changing a given host's closure (an
#      opencode overlay bump, for instance: overlays are lazy, so a package no
#      host installs cannot alter any closure) leaves that host's recorded path
#      untouched. Nothing moves, so nothing alerts, and the rebuild that
#      "silently changed nothing" is no longer requested.
#
#   3. Same mechanism covers commits that are simply irrelevant to a host.
#
# WHY THIS EVALUATES EVERY HOST
#
# It deliberately does NOT reuse the impacted-hosts path filter from
# ci-linux.yaml. That filter is intentionally conservative -- `overlays/*` and
# `modules/*` map to GLOBAL -- because over-building in CI only costs cached
# CPU. Over-reporting drift, by contrast, is exactly the bug being fixed here.
# Evaluating all hosts unconditionally (~50s for nine hosts, single eval) keeps
# the drift signal exact and completely decoupled from the filter's coarseness.
#
# MANIFEST SHAPE
#
#   {
#     "schema": 1,
#     "generated_at": <unix seconds>,
#     "rev": "<commit this run evaluated>",
#     "hosts": {
#       "<host>": {
#         "history": [
#           { "toplevel": "/nix/store/...", "rev": "<sha>", "at": <unix seconds> },
#           ...
#         ]
#       }
#     }
#   }
#
# `history` is newest-first and `history[0]` is always the currently expected
# closure. Entries are appended only when a host's path actually changes, so
# `history[0].at` answers "when did main last change this host?" -- the value
# the drift alert measures elapsed time against. Older entries let a host tell
# "running a genuinely older managed build" (drifted) apart from "running
# something main never produced" (unmanaged), and let a running path be mapped
# back to the commit that introduced it now that the revision is no longer
# baked into the closure.
#
# Usage:
#   scripts/gen-fleet-manifest.sh <output-path> [rev]
#
# `rev` defaults to HEAD of the current checkout. The output file is written
# atomically; if it already exists it is used as the previous manifest so
# unchanged hosts carry their history forward.

set -euo pipefail

OUT="${1:?usage: gen-fleet-manifest.sh <output-path> [rev]}"
REV="${2:-$(git rev-parse HEAD)}"

# Cap on per-host history length. This only needs to be long enough to
# recognise a host that is a few deploys behind; beyond that the distinction
# between "very old managed build" and "unmanaged" stops being useful, and an
# unbounded list would grow the file every host-affecting commit forever.
MAX_HISTORY=25

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

for tool in nix jq git; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "error: required tool not on PATH: $tool" >&2
        exit 1
    }
done

NOW="$(date +%s)"

# Evaluate every host's toplevel output path in a single eval.
#
# stderr is captured to a file rather than merged into stdout: nix prints
# "Using saved setting for 'extra-substituters = ...'" notices for this flake's
# nixConfig whenever the invoking user is not a trusted user, and folding those
# into the JSON would corrupt it. This is the same trap the impacted-hosts
# script documents.
EVAL_STDERR="$(mktemp)"
trap 'rm -f "$EVAL_STDERR"' EXIT

echo "Evaluating system.build.toplevel for every host (rev ${REV})..." >&2

if ! PATHS_JSON="$(
    nix eval --json .#nixosConfigurations \
        --apply 'cfgs: builtins.mapAttrs (_: c: c.config.system.build.toplevel.outPath) cfgs' \
        2>"$EVAL_STDERR"
)"; then
    printf 'error: failed to evaluate host toplevels:\n%s\n' "$(cat "$EVAL_STDERR")" >&2
    exit 1
fi

# Mirror the CI policy that an evaluation warning is a failure. A warning does
# not by itself change an output path, but publishing a manifest from a tree
# that CI would have rejected would advertise paths for a commit that is not
# actually deployable.
if grep -q 'evaluation warning:' "$EVAL_STDERR"; then
    printf 'error: evaluation produced warnings:\n%s\n' "$(cat "$EVAL_STDERR")" >&2
    exit 1
fi

# An empty or non-object result means the flake changed shape; publishing it
# would silently blank the manifest and disable drift detection fleet-wide.
if [[ "$(jq -r 'type' <<<"$PATHS_JSON")" != "object" ]] ||
    [[ "$(jq -r 'length' <<<"$PATHS_JSON")" -eq 0 ]]; then
    echo "error: host evaluation produced no hosts -- refusing to publish" >&2
    exit 1
fi

echo "Evaluated $(jq -r 'length' <<<"$PATHS_JSON") host(s)." >&2

# Previous manifest, if any. A malformed existing file is treated as absent
# rather than fatal so a corrupted manifest self-heals on the next run.
if [[ -f "$OUT" ]] && jq -e . "$OUT" >/dev/null 2>&1; then
    OLD_JSON="$(cat "$OUT")"
else
    OLD_JSON='{}'
fi

NEW_JSON="$(
    jq -n \
        --argjson old "$OLD_JSON" \
        --argjson paths "$PATHS_JSON" \
        --arg rev "$REV" \
        --argjson now "$NOW" \
        --argjson maxHistory "$MAX_HISTORY" \
        '
        {
          schema: 1,
          generated_at: $now,
          rev: $rev,
          hosts: (
            $paths
            | to_entries
            | map(
                .key as $host
                | .value as $path
                | (($old.hosts // {})[$host].history // []) as $history
                | {
                    key: $host,
                    value: {
                      history: (
                        # Prepend only when the expected closure actually
                        # changed. This is what keeps history[0].at meaning
                        # "when main last changed this host" rather than
                        # "when this workflow last ran".
                        if ($history | length) > 0 and $history[0].toplevel == $path
                        then $history
                        else [ { toplevel: $path, rev: $rev, at: $now } ] + $history
                        end
                      )[0:$maxHistory]
                    }
                  }
              )
            | from_entries
          )
        }
        '
)"

mkdir -p "$(dirname "$OUT")"
printf '%s\n' "$NEW_JSON" | jq -S . >"${OUT}.tmp"
mv "${OUT}.tmp" "$OUT"

# Report what moved, so the workflow log answers "which hosts did this commit
# actually affect?" directly.
CHANGED="$(jq -r --arg rev "$REV" '
    .hosts | to_entries
    | map(select(.value.history[0].rev == $rev))
    | map(.key) | join(" ")
' "$OUT")"

if [[ -n "$CHANGED" ]]; then
    echo "Hosts whose expected closure changed at ${REV}: ${CHANGED}" >&2
else
    echo "No host's expected closure changed at ${REV}." >&2
fi
