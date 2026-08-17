#!/usr/bin/env bash
#
# check-colmena-parity.sh -- assert that colmena would deploy the same
# closures that `nixosConfigurations` describes.
#
# WHY THIS EXISTS
#
# `flake/deployment/colmena.nix` and `nixosConfigurations` are two independent
# evaluation paths through the same host modules, and they can silently
# diverge. It has actually happened: nixpkgs' `lib.nixosSystem` passes a
# flake-extended `lib` into eval-config, colmena calls eval-config directly
# with the plain `pkgs.lib`, and `system.nixos.versionSuffix` consequently came
# out as `pre-git` instead of `.<date>.<shortRev>` -- which made colmena
# produce a DIFFERENT store path than nixosConfigurations for every host at the
# same commit. See the comment in flake/deployment/colmena.nix for the full
# incident.
#
# scripts/gen-fleet-manifest.sh already runs this exact check before
# publishing the fleet manifest, but that only happens on push to main and a
# 6-hour schedule -- a regression can merge with CI green and not surface for
# hours. This script is the standalone, PR-time version of the same check: it
# is a pure Nix eval (colmenaHive is colmena.lib.makeHive; .outPath needs no
# realisation), so it is cheap enough to run in CI on every pull request.
#
# gen-fleet-manifest.sh calls this script rather than duplicating the
# comparison, so there is exactly one copy of the parity logic in the repo.
#
# OUTPUT CONTRACT
#
# All diagnostics go to stderr. On success, the nixosConfigurations ->
# toplevel-outPath JSON object (the same shape gen-fleet-manifest.sh needs for
# its own manifest work) is printed to stdout, and the script exits 0. On any
# failure -- including a genuine parity mismatch -- nothing is printed to
# stdout and the script exits non-zero.
#
# Usage:
#   scripts/check-colmena-parity.sh
set -euo pipefail

# Located via BASH_SOURCE rather than `git rev-parse`, for two reasons: it
# does not require git merely to find the repo root (the tool check below
# cannot fire if discovery itself dies on a missing git first), and it works
# from inside a sandboxed Nix build, where there is no .git at all. Matches
# check-sops-recipients.sh, check-doc-drift.sh and check-opencode-jsonc.sh.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# git is deliberately NOT in this list: nothing below shells out to it.
for tool in nix jq; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "error: required tool not on PATH: $tool" >&2
        exit 1
    }
done

# Evaluate every host's toplevel output path in a single eval.
#
# stderr is captured to a file rather than merged into stdout: nix prints
# "Using saved setting for 'extra-substituters = ...'" notices for this flake's
# nixConfig whenever the invoking user is not a trusted user, and folding those
# into the JSON would corrupt it. This is the same trap the impacted-hosts
# script documents.
EVAL_STDERR="$(mktemp)"
COLMENA_STDERR="$(mktemp)"
trap 'rm -f "$EVAL_STDERR" "$COLMENA_STDERR"' EXIT

echo "Evaluating system.build.toplevel for every host..." >&2

if ! PATHS_JSON="$(
    nix eval --json .#nixosConfigurations \
        --apply 'cfgs: builtins.mapAttrs (_: c: c.config.system.build.toplevel.outPath) cfgs' \
        2>"$EVAL_STDERR"
)"; then
    printf 'error: failed to evaluate host toplevels:\n%s\n' "$(cat "$EVAL_STDERR")" >&2
    exit 1
fi

# Mirror the CI policy that an evaluation warning is a failure. A warning
# would otherwise never surface here, and it is exactly the kind of thing that
# can precede a genuine eval-path divergence.
if grep -q 'evaluation warning:' "$EVAL_STDERR"; then
    printf 'error: evaluation produced warnings:\n%s\n' "$(cat "$EVAL_STDERR")" >&2
    exit 1
fi

# An empty or non-object result means the flake changed shape; comparing
# against it would silently report parity for zero hosts.
if [[ "$(jq -r 'type' <<<"$PATHS_JSON")" != "object" ]] ||
    [[ "$(jq -r 'length' <<<"$PATHS_JSON")" -eq 0 ]]; then
    echo "error: host evaluation produced no hosts -- refusing to check parity" >&2
    exit 1
fi

echo "Evaluated $(jq -r 'length' <<<"$PATHS_JSON") host(s)." >&2

# Assert that what colmena would deploy matches nixosConfigurations.
#
# This is the regression guard for the incident described in the header
# comment above: colmena's plain `pkgs.lib` versus the flake-extended `lib`
# producing different `versionSuffix` values, which made the entire fleet
# report as `unmanaged`. Nothing else in CI evaluates colmenaHive, so without
# this check the two paths can silently diverge again -- a nixpkgs change to
# that lib overlay, or a colmena bump, would be enough.
echo "Verifying colmena and nixosConfigurations agree..." >&2

if ! COLMENA_JSON="$(
    nix eval --json '.#colmenaHive.nodes' \
        --apply 'ns: builtins.mapAttrs (_: n: n.config.system.build.toplevel.outPath) ns' \
        2>"$COLMENA_STDERR"
)"; then
    printf 'error: failed to evaluate colmenaHive nodes:\n%s\n' "$(cat "$COLMENA_STDERR")" >&2
    echo "       Cannot confirm colmena describes deployable paths; treating as a mismatch." >&2
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
# report "agree for 0 servers" as if parity held. Mirrors the identical guard
# applied to PATHS_JSON above.
if [[ "$(jq -r 'type' <<<"$COLMENA_JSON")" != "object" ]] ||
    [[ "$(jq -r 'length' <<<"$COLMENA_JSON")" -eq 0 ]]; then
    echo "error: colmena evaluation produced no nodes -- refusing to check parity" >&2
    exit 1
fi

# A colmena node with no nixosConfigurations entry counts as a mismatch rather
# than being skipped. Such a node should be unreachable -- mkNode dereferences
# `self.nixosConfigurations.<name>._colmena`, so a missing entry throws during
# evaluation and is caught above -- but suppressing the case would hide exactly
# the failure this guard exists to report: a host colmena deploys that
# nixosConfigurations has no path for.
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
error: colmena would deploy different closures than nixosConfigurations describes.

$MISMATCHED

Every affected host would report deploy state 'unmanaged' forever, because its
running closure is a path the fleet manifest can never contain.

Fix the divergence (see flake/deployment/colmena.nix) rather than this check.
EOF
    exit 1
fi

echo "colmena and nixosConfigurations agree for $(jq -r 'length' <<<"$COLMENA_JSON") server(s)." >&2

printf '%s\n' "$PATHS_JSON"
