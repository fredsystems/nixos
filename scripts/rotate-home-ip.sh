#!/usr/bin/env bash
#
# rotate-home-ip.sh -- point the fleet at a new home public IPv4 address.
#
# The ISP rotates the residential address often. When it does,
# HomePublicIPDrifted fires and shared.homePublicIPv4 in
# modules/data/home-network.nix has to follow: fredvps's fail2ban ignoreIP
# list is built from it, and its decoy jails ban on the first knock. This does
# the whole remediation in one command:
#
#   1. Works out the new address and cross-checks it (see below).
#   2. Shows old -> new and asks before changing anything.
#   3. In a throwaway worktree off origin/main -- your checkout is never
#      touched, dirty or not -- rewrites the value, asks
#      scripts/impacted-hosts.sh which hosts that changes, and evaluates them.
#   4. Commits, pushes, opens a PR and queues it for auto-merge.
#   5. Deploys the impacted hosts with colmena and verifies the result:
#      each host runs the new closure, sdrhub's drift check reports a match,
#      and fredvps's sshd jail ignores the new address and not the old one.
#
# WHY A HUMAN STAYS IN THE LOOP
#
# sdrhub's drift check reads the address from the newest fredvps nginx log
# line carrying a Blackbox-Exporter User-Agent. Anyone on the internet can
# send that User-Agent. As an alert input that is harmless; fed straight into
# ignoreIP it would let a stranger whitelist themselves on the one
# internet-facing host. So this never acts on that value alone:
#
#   * The address must also be reported by an independent echo service,
#     queried FROM sdrhub (it sits behind the home NAT), so the answer is the
#     same wherever this script runs. Some echo services are blocked by the
#     home DNS filter; the ones listed below are known to answer, and every
#     one that answers must agree.
#   * It must sit inside the ISP's block (HOME_ISP_CIDR). An address outside
#     it can still be accepted, but only interactively, never with --yes.
#   * You confirm old -> new before anything is written.
#
# An explicit address argument skips the auto-detection but not the checks: a
# disagreement with the echo services must be confirmed interactively.
#
# DEPLOY SAFETY
#
# The PR is cut from origin/main, so a host already running origin/main's
# closure receives exactly the address change and nothing else -- safe for a
# live `switch`. A host running anything else would also pick up whatever it
# is behind on, which is colmena-apply-drifted.sh's job (it has the
# switch-vs-boot guards). For such a host this asks before deploying, and
# with --yes it skips the deploy entirely.
#
# Deploying ahead of the merge means the hosts report NixOSDeployStateUnknown
# until the PR merges and the fleet manifest republishes. That is expected and
# clears by itself; auto-merge is queued for exactly that reason.
#
# Usage:
#   scripts/rotate-home-ip.sh                  # detect, confirm, ship, deploy
#   scripts/rotate-home-ip.sh 168.93.60.127    # use this address
#   scripts/rotate-home-ip.sh --dry-run        # detect and report only
#   scripts/rotate-home-ip.sh --no-deploy      # stop after opening the PR
#   scripts/rotate-home-ip.sh --no-auto-merge  # open the PR without queueing it
#   scripts/rotate-home-ip.sh --yes            # no prompts; refuses anything
#                                              # that would otherwise need one
#                                              # beyond the old -> new check
#
# EXIT CODES
#
#   0  rotated and verified, or already up to date
#   1  error, or refused
#   2  PR opened but the deploy was skipped or did not verify

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/home-ip.sh
source "$REPO_ROOT/scripts/lib/home-ip.sh"

NIX_FILE="modules/data/home-network.nix"

# Ezee Fiber residential space. Keep in step with the description of
# shared.homePublicIPv4 if the ISP changes.
HOME_ISP_CIDR="168.93.0.0/18"

# The node that runs the drift check and sits behind the home NAT, and the
# internet-facing node whose ignoreIP list this is all for.
OBSERVER_NODE="sdrhub"
ENFORCER_NODE="fredvps"

DRIFT_TEXTFILE="/var/lib/node_exporter/textfiles/home_public_ip.prom"
ECHO_URLS=("https://ifconfig.me" "https://ifconfig.co/ip")

DRY_RUN=0
DEPLOY=1
AUTO_MERGE=1
ASSUME_YES=0
EXPLICIT_IP=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --no-deploy) DEPLOY=0 ;;
        --no-auto-merge) AUTO_MERGE=0 ;;
        --yes | -y) ASSUME_YES=1 ;;
        -h | --help)
            awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
            exit 0
            ;;
        -*)
            echo "error: unknown argument: $1" >&2
            exit 1
            ;;
        *)
            [[ -z "$EXPLICIT_IP" ]] || {
                echo "error: more than one address given" >&2
                exit 1
            }
            EXPLICIT_IP="$1"
            ;;
    esac
    shift
done

die() {
    printf 'rotate-home-ip: %s\n' "$*" >&2
    exit 1
}
step() { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }

# confirm <prompt> -- y/N. With --yes, answers yes.
confirm() {
    [[ $ASSUME_YES -eq 1 ]] && return 0
    local reply
    read -r -p "$1 [y/N] " reply </dev/tty || return 1
    [[ "$reply" == [yY] || "$reply" == [yY][eE][sS] ]]
}

# confirm_risky <prompt> -- for anything outside the normal path. --yes does
# NOT answer this one; unattended runs refuse instead.
confirm_risky() {
    if [[ $ASSUME_YES -eq 1 ]]; then
        warn "$1 -- refusing under --yes; rerun interactively to override"
        return 1
    fi
    local reply
    read -r -p "$1 Type 'yes' to continue: " reply </dev/tty || return 1
    [[ "$reply" == "yes" ]]
}

if [[ -n "$EXPLICIT_IP" ]]; then
    hip_is_ipv4 "$EXPLICIT_IP" || die "not a valid IPv4 address: $EXPLICIT_IP"
fi

for tool in git nix jq ssh colmena gh timeout; do
    command -v "$tool" >/dev/null || die "$tool is not on PATH (run from the dev shell)"
done

# ---------------------------------------------------------------------------
# Worktree
# ---------------------------------------------------------------------------

WT=""
BRANCH=""
PUSHED=0
cleanup() {
    if [[ -n "$WT" && -d "$WT" ]]; then
        git -C "$REPO_ROOT" worktree remove --force "$WT" >/dev/null 2>&1 || true
    fi
    # Pushed means the remote holds it; the local copy is only clutter. An
    # unpushed branch is kept so nothing is lost.
    if [[ -n "$BRANCH" && $PUSHED -eq 1 ]]; then
        git -C "$REPO_ROOT" branch -D "$BRANCH" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

step "Fetching origin/main"
git -C "$REPO_ROOT" fetch --quiet origin main || die "git fetch failed"
BASE_SHA="$(git -C "$REPO_ROOT" rev-parse origin/main)"

CURRENT="$(git -C "$REPO_ROOT" show "origin/main:$NIX_FILE" | hip_current_value)" ||
    die "could not find exactly one address in $NIX_FILE on origin/main"
echo "configured on origin/main: $CURRENT"

WT="$(mktemp -d)"
rmdir "$WT"
git -C "$REPO_ROOT" worktree add --quiet --detach "$WT" "$BASE_SHA" ||
    die "could not create a worktree at $WT"
# The hook config is a gitignored symlink into the store, so a fresh
# worktree lacks it and `git commit` would fail before running any hook.
if [[ -L "$REPO_ROOT/.pre-commit-config.yaml" ]]; then
    cp -P "$REPO_ROOT/.pre-commit-config.yaml" "$WT/"
fi

step "Reading deployment topology"
DEPLOY_JSON="$(cd "$WT" && nix eval --json '.#colmenaHive.deploymentConfig' 2>/dev/null)" ||
    die "could not evaluate colmenaHive.deploymentConfig"

# node_ssh <node> [cmd...] -- with no command, runs stdin under /bin/sh -s
# (the login shell is zsh, which does not word-split; see
# colmena-apply-drifted.sh).
node_ssh() {
    local node="$1" host port user
    shift
    host="$(jq -er --arg n "$node" '.[$n].targetHost' <<<"$DEPLOY_JSON")" || return 1
    port="$(jq -r --arg n "$node" '.[$n].targetPort // 22' <<<"$DEPLOY_JSON")"
    user="$(jq -r --arg n "$node" '.[$n].targetUser // "root"' <<<"$DEPLOY_JSON")"
    if [[ $# -eq 0 ]]; then
        set -- /bin/sh -s
    fi
    timeout 60 ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes \
        -p "$port" "${user}@${host}" "$@"
}

# ---------------------------------------------------------------------------
# Observe
# ---------------------------------------------------------------------------

step "Observing the home address"

NGINX_OBS="$(node_ssh "$OBSERVER_NODE" cat "$DRIFT_TEXTFILE" 2>/dev/null | hip_parse_observed)" || NGINX_OBS=""
printf '  %-28s %s\n' "fredvps nginx (drift check)" "${NGINX_OBS:-no answer}"

ECHO_OBS=()
for url in "${ECHO_URLS[@]}"; do
    answer="$(node_ssh "$OBSERVER_NODE" curl -4 -fsS --max-time 10 "$url" 2>/dev/null | tr -d '[:space:]')" || answer=""
    hip_is_ipv4 "$answer" || answer=""
    ECHO_OBS+=("$answer")
    printf '  %-28s %s\n' "$url" "${answer:-no answer}"
done

ECHO_AGREED="$(hip_consensus "${ECHO_OBS[@]}")" || ECHO_AGREED=""

if [[ -n "$EXPLICIT_IP" ]]; then
    NEW="$EXPLICIT_IP"
    if [[ "$NEW" != "$ECHO_AGREED" ]]; then
        confirm_risky "$NEW does not match what the echo services report (${ECHO_AGREED:-no consensus})." ||
            die "refused"
    fi
else
    [[ -n "$ECHO_AGREED" ]] ||
        die "the echo services did not answer or disagree; pass the address explicitly"
    [[ -n "$NGINX_OBS" ]] ||
        die "sdrhub's drift check has no observed address; pass the address explicitly"
    [[ "$NGINX_OBS" == "$ECHO_AGREED" ]] ||
        die "fredvps sees $NGINX_OBS but the echo services see $ECHO_AGREED; investigate before whitelisting either"
    NEW="$ECHO_AGREED"
fi

if ! hip_in_cidr "$NEW" "$HOME_ISP_CIDR"; then
    confirm_risky "$NEW is outside the ISP block $HOME_ISP_CIDR." || die "refused"
fi

if [[ "$NEW" == "$CURRENT" ]]; then
    echo
    echo "origin/main is already configured for $NEW; nothing to rotate."
    echo "If the alert is still firing, a host is behind: scripts/colmena-apply-drifted.sh"
    exit 0
fi

BRANCH="$(hip_branch_name "$NEW")"
existing="$(gh pr list --head "$BRANCH" --state open --json url --jq '.[0].url // empty' 2>/dev/null || true)"
[[ -z "$existing" ]] || die "a PR for $NEW is already open: $existing"
if git -C "$REPO_ROOT" show-ref --quiet "refs/heads/$BRANCH"; then
    die "local branch $BRANCH already exists; delete it or finish that rotation first"
fi

echo
echo "  $CURRENT  ->  $NEW"
echo

if [[ $DRY_RUN -eq 1 ]]; then
    echo "dry run: nothing changed"
    exit 0
fi

confirm "Rotate the home address to $NEW?" || die "aborted"

# ---------------------------------------------------------------------------
# Change and evaluate
# ---------------------------------------------------------------------------

step "Updating $NIX_FILE"
tmp="$(mktemp)"
hip_replace_value "$CURRENT" "$NEW" <"$WT/$NIX_FILE" >"$tmp" ||
    die "could not rewrite $NIX_FILE"
mv "$tmp" "$WT/$NIX_FILE"
git -C "$WT" switch --quiet -c "$BRANCH"
git -C "$WT" diff --stat

step "Finding impacted hosts"
impact="$(cd "$WT" && ./scripts/impacted-hosts.sh --os linux --json origin/main)" ||
    die "impacted-hosts.sh failed"
mapfile -t HOSTS < <(jq -r '.hosts[]' <<<"$impact")
[[ ${#HOSTS[@]} -gt 0 ]] || die "no hosts are impacted by the change -- is the option still read?"
echo "impacted: ${HOSTS[*]}"
for h in "$OBSERVER_NODE" "$ENFORCER_NODE"; do
    [[ " ${HOSTS[*]} " == *" $h "* ]] ||
        die "$h is not impacted by the change, which should be impossible; refusing"
done

# hostname -> closure, evaluated (never built). Evaluation warnings fail CI,
# so they fail here too.
declare -A BASE_OUT NEW_OUT
eval_out() { # <flake-ref> <host>
    local err out
    err="$(mktemp)"
    if ! out="$(nix eval --raw "$1#nixosConfigurations.$2.config.system.build.toplevel.outPath" 2>"$err")"; then
        cat "$err" >&2
        rm -f "$err"
        return 1
    fi
    if grep -q 'evaluation warning:' "$err"; then
        cat "$err" >&2
        rm -f "$err"
        return 1
    fi
    rm -f "$err"
    printf '%s\n' "$out"
}

step "Evaluating"
for h in "${HOSTS[@]}"; do
    NEW_OUT[$h]="$(eval_out "$WT" "$h")" || die "$h failed to evaluate"
    BASE_OUT[$h]="$(eval_out "git+file://$REPO_ROOT?rev=$BASE_SHA" "$h")" ||
        die "$h failed to evaluate at origin/main"
    echo "  $h OK"
done

# ---------------------------------------------------------------------------
# Commit, push, PR
# ---------------------------------------------------------------------------

step "Committing"
git -C "$WT" add "$NIX_FILE"
git -C "$WT" commit --quiet -F - <<EOF
fix(home-network): rotate home public IP to $NEW

The ISP rotated the residential address from $CURRENT. Confirmed by
fredvps's nginx log (${NGINX_OBS:-no answer}) and by echo services queried
from sdrhub (${ECHO_AGREED:-no consensus}). Updates fredvps's fail2ban
ignoreIP and sdrhub's drift check.

Generated by scripts/rotate-home-ip.sh.
EOF

step "Pushing and opening the PR"
git -C "$WT" push --quiet -u origin "$BRANCH"
PUSHED=1
PR_URL="$(cd "$WT" && gh pr create --fill)" || die "gh pr create failed (branch $BRANCH is pushed)"
echo "$PR_URL"
if [[ $AUTO_MERGE -eq 1 ]]; then
    (cd "$WT" && gh pr merge "$PR_URL" --auto --merge >/dev/null 2>&1) ||
        warn "could not enable auto-merge; merge $PR_URL by hand"
fi

if [[ $DEPLOY -eq 0 ]]; then
    echo
    echo "PR open; not deploying (--no-deploy). The alert clears once ${HOSTS[*]} are deployed."
    exit 2
fi

# ---------------------------------------------------------------------------
# Deploy
# ---------------------------------------------------------------------------

step "Checking what the hosts are running"
DEPLOY_HOSTS=()
for h in "${HOSTS[@]}"; do
    running="$(node_ssh "$h" readlink -f /run/current-system 2>/dev/null)" || running=""
    if [[ "$running" == "${NEW_OUT[$h]}" ]]; then
        echo "  $h already runs the new closure"
    elif [[ "$running" == "${BASE_OUT[$h]}" ]]; then
        echo "  $h runs origin/main; the deploy changes only the address"
        DEPLOY_HOSTS+=("$h")
    else
        echo "  $h runs ${running:-<unreachable>}, which is not origin/main"
        if confirm_risky "Deploying $h would also apply everything it is behind on (colmena-apply-drifted.sh is the guarded route)."; then
            DEPLOY_HOSTS+=("$h")
        else
            echo
            echo "Not deploying. Bring the fleet up to date with scripts/colmena-apply-drifted.sh,"
            echo "then rerun this script; it will see origin/main is current and stop, or merge $PR_URL first."
            exit 2
        fi
    fi
done

if [[ ${#DEPLOY_HOSTS[@]} -gt 0 ]]; then
    step "Deploying ${DEPLOY_HOSTS[*]}"
    on="$(IFS=,; echo "${DEPLOY_HOSTS[*]}")"
    (cd "$WT" && colmena apply --on "$on" switch) || {
        warn "colmena apply failed; the PR is open at $PR_URL"
        exit 2
    }
fi

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------

step "Verifying"
VERIFY_FAIL=0
for h in "${HOSTS[@]}"; do
    running="$(node_ssh "$h" readlink -f /run/current-system 2>/dev/null)" || running=""
    if [[ "$running" == "${NEW_OUT[$h]}" ]]; then
        echo "  $h runs the new closure"
    else
        warn "$h runs ${running:-<unreachable>}, expected ${NEW_OUT[$h]}"
        VERIFY_FAIL=1
    fi
done

prom="$(node_ssh "$OBSERVER_NODE" <<'SH' 2>/dev/null
sudo systemctl start home-ip-drift-metric.service && cat /var/lib/node_exporter/textfiles/home_public_ip.prom
SH
)" || prom=""
if grep -qF "observed=\"$NEW\",expected=\"$NEW\"} 1" <<<"$prom"; then
    echo "  $OBSERVER_NODE drift check: match"
else
    warn "$OBSERVER_NODE drift check does not report a match yet:"
    grep matches_expected <<<"$prom" >&2 || echo "  (no series)" >&2
    VERIFY_FAIL=1
fi

ignore="$(node_ssh "$ENFORCER_NODE" sudo fail2ban-client get sshd ignoreip 2>/dev/null)" || ignore=""
if hip_ignoreip_has "$NEW" <<<"$ignore" && ! hip_ignoreip_has "$CURRENT" <<<"$ignore"; then
    echo "  $ENFORCER_NODE sshd ignoreip: has $NEW, $CURRENT removed"
else
    warn "$ENFORCER_NODE sshd ignoreip is not as expected:"
    printf '%s\n' "${ignore:-  (no answer)}" >&2
    VERIFY_FAIL=1
fi

echo
if [[ $VERIFY_FAIL -ne 0 ]]; then
    warn "deployed, but verification did not pass; see above. PR: $PR_URL"
    exit 2
fi
echo "Done. $CURRENT -> $NEW is live. PR: $PR_URL"
echo "Hosts will report NixOSDeployStateUnknown until the PR merges and the fleet manifest republishes."
