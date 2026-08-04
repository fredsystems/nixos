#!/usr/bin/env bash
#
# colmena-apply-drifted.sh -- deploy only the servers that are actually out of
# date, and refuse to deploy ahead of the published fleet manifest.
#
# WHAT IT DOES
#
#   1. Evaluates the toplevel store path colmena would deploy for every node.
#   2. Checks each of those paths against the published fleet manifest, and
#      stops if the manifest has not caught up (see THE MANIFEST GUARD below).
#   3. Asks each node over SSH what it is actually running.
#   4. Runs `colmena apply --on <nodes>` for just the ones that differ.
#
# Topology is read from `colmenaHive.deploymentConfig`, which is the same data
# colmena itself deploys from, so target hosts, ports and users cannot drift out
# of sync with the node table in flake/hosts/servers.nix.
#
# THE MANIFEST GUARD
#
# The fleet manifest is published by a workflow that runs AFTER a merge, and each
# host only compares itself against the manifest on a timer. Merge and deploy
# quickly and you land in a window where a host is running a closure the manifest
# has never heard of. The host cannot tell that apart from a hand-built WIP
# system on its own, so it reports a deploy state of `unknown` until the manifest
# publishes and it refetches.
#
# That window is harmless when the workflow is simply a couple of minutes behind.
# It is NOT harmless when the workflow has failed: then the manifest never catches
# up, drift detection for that host stays blind indefinitely, and the only signal
# is a NixOSDeployStateUnknown alert twelve hours later. This guard is what tells
# those two situations apart before you deploy rather than after.
#
# The check is per-host closure equality, not a commit comparison. That matters:
# a commit that does not change a given host's closure leaves the manifest still
# correct for it, so such a host is safe to deploy even though the manifest's
# recorded revision is older than HEAD. Comparing revisions would refuse those
# deploys for no reason.
#
# Local evaluation uses colmenaHive while the manifest is generated from
# nixosConfigurations. Those two are byte-identical by construction, and
# scripts/gen-fleet-manifest.sh refuses to publish if they ever stop being, so
# comparing one against the other is sound.
#
# WHY SSH RATHER THAN THE PROMETHEUS METRIC
#
# nixos_deploy_state would answer "who is drifted" in a single query, but it is
# only as fresh as each host's last timer run. A stale metric can report a host
# as current when it is not, and this script would then skip the one host that
# needed deploying. SSH is ground truth, and colmena needs it anyway.
#
# Usage:
#   scripts/colmena-apply-drifted.sh                 # guard, report, deploy
#   scripts/colmena-apply-drifted.sh --dry-run       # report only
#   scripts/colmena-apply-drifted.sh --wait          # poll for the manifest
#   scripts/colmena-apply-drifted.sh --force         # deploy despite the guard
#   scripts/colmena-apply-drifted.sh -- --verbose    # pass args to colmena

set -euo pipefail

MANIFEST_URL="https://raw.githubusercontent.com/fredsystems/nixos/fleet-manifest/manifest.json"

# How long --wait will poll for the manifest to catch up. The publishing workflow
# evaluates every host (~1 minute) on top of runner startup, so a few minutes is
# the normal case; ten minutes means something is wrong rather than slow.
WAIT_TIMEOUT=600
WAIT_INTERVAL=15

DRY_RUN=0
FORCE=0
WAIT=0
COLMENA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --force) FORCE=1 ;;
        --wait) WAIT=1 ;;
        --) shift; COLMENA_ARGS=("$@"); break ;;
        -h | --help)
            sed -n '2,55p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1 (use -- to pass args to colmena)" >&2
            exit 1
            ;;
    esac
    shift
done

for tool in nix jq git ssh curl colmena; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "error: required tool not on PATH: $tool" >&2
        exit 1
    }
done

cd "$(git rev-parse --show-toplevel)"

if [[ -n "$(git status --porcelain)" ]]; then
    cat >&2 <<'EOF'
warning: the working tree is dirty.

  A dirty tree evaluates to closures that no commit produced, so the manifest
  cannot contain them and every host you deploy will report deploy state
  'unmanaged' until you deploy again from a clean tree. That is the drift check
  working correctly, not a false alarm.

EOF
fi

# stderr is kept out of stdout: nix prints "Using saved setting for
# 'extra-substituters = ...'" notices for this flake's nixConfig whenever the
# invoking user is not trusted, and folding those in would corrupt the JSON.
EVAL_STDERR="$(mktemp)"
trap 'rm -f "$EVAL_STDERR"' EXIT

echo "Evaluating what colmena would deploy..." >&2
if ! EXPECTED_JSON="$(
    nix eval --json '.#colmenaHive.nodes' \
        --apply 'ns: builtins.mapAttrs (_: n: n.config.system.build.toplevel.outPath) ns' \
        2>"$EVAL_STDERR"
)"; then
    printf 'error: failed to evaluate colmenaHive nodes:\n%s\n' "$(cat "$EVAL_STDERR")" >&2
    exit 1
fi

if ! DEPLOY_JSON="$(nix eval --json '.#colmenaHive.deploymentConfig' 2>>"$EVAL_STDERR")"; then
    printf 'error: failed to evaluate colmenaHive deploymentConfig:\n%s\n' "$(cat "$EVAL_STDERR")" >&2
    exit 1
fi

mapfile -t NODES < <(jq -r 'keys[]' <<<"$EXPECTED_JSON")
if [[ ${#NODES[@]} -eq 0 ]]; then
    echo "error: colmenaHive has no nodes" >&2
    exit 1
fi
echo "Evaluated ${#NODES[@]} node(s)." >&2

# --- Manifest guard -------------------------------------------------------

# Returns the space-separated list of nodes whose locally-evaluated closure is
# not the one the published manifest currently expects for them.
manifest_lagging_nodes() {
    local manifest
    manifest="$(curl -sfL --max-time 30 "$MANIFEST_URL" 2>/dev/null || echo "")"

    if [[ -z "$manifest" ]] || ! jq -e '.schema == 1' <<<"$manifest" >/dev/null 2>&1; then
        echo "__FETCH_FAILED__"
        return 0
    fi

    jq -rn --argjson expected "$EXPECTED_JSON" --argjson m "$manifest" '
        $expected | to_entries
        | map(select(
            ($m.hosts[.key].history[0].toplevel // "") != .value
          ) | .key)
        | join(" ")
    '
}

if [[ $FORCE -eq 1 ]]; then
    echo "Skipping the manifest guard (--force)." >&2
else
    LAGGING="$(manifest_lagging_nodes)"

    if [[ $WAIT -eq 1 && -n "$LAGGING" ]]; then
        echo "Manifest has not caught up yet; waiting up to ${WAIT_TIMEOUT}s..." >&2
        WAITED=0
        while [[ -n "$LAGGING" && "$WAITED" -lt "$WAIT_TIMEOUT" ]]; do
            sleep "$WAIT_INTERVAL"
            WAITED=$((WAITED + WAIT_INTERVAL))
            LAGGING="$(manifest_lagging_nodes)"
            [[ -z "$LAGGING" ]] && echo "Manifest caught up after ${WAITED}s." >&2
        done
    fi

    if [[ "$LAGGING" == "__FETCH_FAILED__" ]]; then
        cat >&2 <<EOF
error: could not fetch the fleet manifest.

  Deploying now would leave every host unable to determine its deploy state.
  Check network access to raw.githubusercontent.com, or pass --force if you
  accept that consequence.
EOF
        exit 1
    fi

    if [[ -n "$LAGGING" ]]; then
        cat >&2 <<EOF
error: the published manifest does not yet describe the closures you are about
       to deploy, for: $LAGGING

  Either the fleet-manifest workflow has not finished for the current commit, or
  it failed. Deploying now leaves those hosts reporting deploy state 'unknown'
  until it publishes; if it failed, that is indefinite.

  Check:  gh run list --workflow=fleet-manifest.yaml --limit 3
  Wait:   $0 --wait
  Ignore: $0 --force
EOF
        exit 1
    fi

    echo "Manifest matches the closures to be deployed." >&2
fi

# --- Determine what each node is actually running -------------------------

DRIFTED=()
CURRENT=()
UNREACHABLE=()

for node in "${NODES[@]}"; do
    expected="$(jq -r --arg n "$node" '.[$n]' <<<"$EXPECTED_JSON")"
    host="$(jq -r --arg n "$node" '.[$n].targetHost // ""' <<<"$DEPLOY_JSON")"
    port="$(jq -r --arg n "$node" '.[$n].targetPort // 22' <<<"$DEPLOY_JSON")"
    user="$(jq -r --arg n "$node" '.[$n].targetUser // "root"' <<<"$DEPLOY_JSON")"

    if [[ -z "$host" ]]; then
        UNREACHABLE+=("$node (no targetHost)")
        continue
    fi

    if ! running="$(
        ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
            -p "$port" "${user}@${host}" 'readlink -f /run/current-system' 2>/dev/null
    )"; then
        UNREACHABLE+=("$node ($host)")
        continue
    fi

    if [[ "$running" == "$expected" ]]; then
        CURRENT+=("$node")
    else
        DRIFTED+=("$node")
    fi
done

printf '\n%-12s %s\n' "current:" "${CURRENT[*]:-none}"
printf '%-12s %s\n' "to deploy:" "${DRIFTED[*]:-none}"
if [[ ${#UNREACHABLE[@]} -gt 0 ]]; then
    # Reported rather than silently skipped: an unreachable node is one colmena
    # could not have deployed either, and treating it as "current" would quietly
    # leave it behind forever.
    printf '%-12s %s\n' "unreachable:" "${UNREACHABLE[*]}"
fi
echo

if [[ ${#DRIFTED[@]} -eq 0 ]]; then
    echo "Nothing to deploy."
    exit 0
fi

TARGETS="$(
    IFS=,
    echo "${DRIFTED[*]}"
)"

if [[ $DRY_RUN -eq 1 ]]; then
    echo "would run: colmena apply --on $TARGETS ${COLMENA_ARGS[*]}"
    exit 0
fi

echo "Running: colmena apply --on $TARGETS ${COLMENA_ARGS[*]}"
exec colmena apply --on "$TARGETS" ${COLMENA_ARGS[@]+"${COLMENA_ARGS[@]}"}
