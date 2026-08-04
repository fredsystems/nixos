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

# Assert that what colmena would deploy matches what this manifest publishes.
#
# This is a regression guard for a bug that made the entire server fleet report
# `unmanaged`. The manifest is generated from `nixosConfigurations`, but servers
# are deployed by colmena, and the two used to evaluate to DIFFERENT store paths
# for the same host at the same commit: nixpkgs' `lib.nixosSystem` passes a
# flake-extended `lib` into eval-config, colmena calls eval-config directly with
# the plain `pkgs.lib`, and `system.nixos.versionSuffix` consequently came out as
# `pre-git` instead of `.<date>.<shortRev>`. The manifest therefore described
# paths that no server would ever be running. See the comment in
# flake/deployment/colmena.nix.
#
# Nothing else in CI evaluates colmenaHive, so without this check the two paths
# can silently diverge again -- a nixpkgs change to that lib overlay, or a
# colmena bump, would be enough. Publishing a manifest that describes
# undeployable paths is worse than not publishing: it marks every server
# unmanaged. So divergence is fatal here rather than a warning.
echo "Verifying colmena and nixosConfigurations agree..." >&2

COLMENA_STDERR="$(mktemp)"
trap 'rm -f "$EVAL_STDERR" "$COLMENA_STDERR"' EXIT

if ! COLMENA_JSON="$(
    nix eval --json '.#colmenaHive.nodes' \
        --apply 'ns: builtins.mapAttrs (_: n: n.config.system.build.toplevel.outPath) ns' \
        2>"$COLMENA_STDERR"
)"; then
    printf 'error: failed to evaluate colmenaHive nodes:\n%s\n' "$(cat "$COLMENA_STDERR")" >&2
    echo "       Cannot confirm the manifest describes deployable paths; refusing to publish." >&2
    exit 1
fi

# Same warnings-are-fatal policy the nixosConfigurations eval above applies.
# This is the only place it can ever be enforced for the colmena evaluator:
# nothing in CI evaluates colmenaHive, so a warning introduced by a nixpkgs or
# colmena bump would otherwise never surface anywhere.
if grep -q 'evaluation warning:' "$COLMENA_STDERR"; then
    printf 'error: colmena evaluation produced warnings:\n%s\n' "$(cat "$COLMENA_STDERR")" >&2
    exit 1
fi

# An empty or non-object node set would make the comparison below vacuous and
# report "agree for 0 servers" on its way to publishing an unverified manifest.
# Mirrors the identical guard applied to PATHS_JSON above.
if [[ "$(jq -r 'type' <<<"$COLMENA_JSON")" != "object" ]] ||
    [[ "$(jq -r 'length' <<<"$COLMENA_JSON")" -eq 0 ]]; then
    echo "error: colmena evaluation produced no nodes -- refusing to publish" >&2
    exit 1
fi

# A colmena node with no nixosConfigurations entry counts as a mismatch rather
# than being skipped. Such a node should be unreachable -- mkNode dereferences
# `self.nixosConfigurations.<name>._colmena`, so a missing entry throws during
# evaluation and is caught above -- but suppressing the case would hide exactly
# the failure this guard exists to report: a host colmena deploys that the
# manifest has no path for, which reports `unmanaged` forever.
MISMATCHED="$(
    jq -rn \
        --argjson a "$PATHS_JSON" \
        --argjson b "$COLMENA_JSON" \
        '$b | to_entries
         | map(select($a[.key] != .value)
               | "  \(.key)\n    nixosConfigurations: \($a[.key] // "<missing>")\n    colmena:             \(.value)")
         | join("\n")'
)"

if [[ -n "$MISMATCHED" ]]; then
    cat >&2 <<EOF
error: colmena would deploy different closures than this manifest publishes.

$MISMATCHED

Every affected host would report deploy state 'unmanaged' forever, because its
running closure is a path the manifest can never contain. Refusing to publish.

Fix the divergence (see flake/deployment/colmena.nix) rather than this check.
EOF
    exit 1
fi

echo "colmena and nixosConfigurations agree for $(jq -r 'length' <<<"$COLMENA_JSON") server(s)." >&2

# Previous manifest, if any. A malformed existing file is treated as absent
# rather than fatal so a corrupted manifest self-heals on the next run.
#
# The structure is validated, not just the syntax. A bare `jq -e .` would accept
# any valid JSON, including shapes this script then indexes as an object --
# `[]`, `"string"`, or a `history` that is not an array. Those raise a jq error
# rather than returning null, and under `set -e` that aborts the run instead of
# self-healing, which would leave the whole fleet without a manifest until
# someone hand-repaired the branch. Checking the shape up front makes the
# self-heal claim above actually true for any corruption, not only for invalid
# JSON.
if [[ -f "$OUT" ]] && jq -e '
    type == "object"
    and ((.hosts // {}) | type == "object")
    and ((.hosts // {}) | all(.[]; (.history // []) | type == "array"))
' "$OUT" >/dev/null 2>&1; then
    OLD_JSON="$(cat "$OUT")"
else
    OLD_JSON='{}'
fi

# Hosts that were published before but are absent now. Reported loudly, but
# deliberately NOT treated as fatal.
#
# A partially-evaluated subset is not reachable here: `nix eval --json` forces
# the whole attrset, so any single host failing to evaluate fails the command
# outright and we exit above. The only way this set is non-empty is a deliberate
# removal from nixosConfigurations, which is a normal operation -- and failing on
# it would wedge the publisher on every subsequent commit until someone
# intervened, taking drift detection down for the entire fleet to report one
# intentional change.
#
# The consequence of a genuinely unintended removal is already covered: the
# dropped host resolves no history, reports `unknown`, and
# NixOSDeployStateUnknown fires. This message is here so the cause is obvious in
# the workflow log when that happens.
DROPPED="$(jq -r --argjson paths "$PATHS_JSON" '
    ((.hosts // {}) | keys) - ($paths | keys) | join(" ")
' <<<"$OLD_JSON")"

if [[ -n "$DROPPED" ]]; then
    echo "WARNING: hosts in the previous manifest are no longer in nixosConfigurations: ${DROPPED}" >&2
    echo "         They will lose their history and report deploy state 'unknown'." >&2
    echo "         Expected after an intentional host removal; otherwise investigate." >&2
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
