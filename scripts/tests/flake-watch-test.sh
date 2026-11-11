#!/usr/bin/env bash
#
# flake-watch-test.sh -- hermetic tests for the flake input watch:
# scripts/flake-watch.sh (candidates, resolve-heads, plan, merge),
# .github/scripts/flake-watch-publish.sh, and
# scripts/check-flake-input-policy.sh (including against the real
# .github/flake-input-policy.json and flake.lock).
#
# No network: resolve-heads gets a fake git through FLAKE_WATCH_GIT, and
# publish pushes to a local bare repository through FLAKE_WATCH_REMOTE.
# Runs as a flake check (`.#checks.<system>.flake-watch`) and a pre-commit
# hook.
#
# Usage: bash scripts/tests/flake-watch-test.sh   (from the repo root)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WATCH="$ROOT/scripts/flake-watch.sh"
PUBLISH="$ROOT/.github/scripts/flake-watch-publish.sh"
POLICY_CHECK="$ROOT/scripts/check-flake-input-policy.sh"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() {
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n' "$1" >&2
    [[ $# -lt 2 ]] || printf '      %s\n' "${@:2}" >&2
}
eq() { # name expected actual
    if [[ "$2" == "$3" ]]; then ok; else bad "$1" "expected: $2" "actual:   $3"; fi
}
has() { # name needle haystack
    if [[ "$3" == *"$2"* ]]; then ok; else bad "$1" "missing: $2" "in:      ${3//$'\n'/ | }"; fi
}

# ---------------------------------------------------------------------------
# candidates
# ---------------------------------------------------------------------------

cat >"$T/flake.lock" <<'EOF'
{
  "nodes": {
    "root": { "inputs": {
      "onbranch": "onbranch", "ondefault": "ondefault", "ontag": "ontag",
      "pinned": "pinned", "tarball-input": "tarball-input", "follower": ["onbranch"]
    } },
    "onbranch":  { "locked": { "type": "github", "owner": "o", "repo": "b", "rev": "b0" },
                  "original": { "type": "github", "owner": "o", "repo": "b", "ref": "main" } },
    "ondefault": { "locked": { "type": "github", "owner": "o", "repo": "d", "rev": "d0" },
                  "original": { "type": "github", "owner": "o", "repo": "d" } },
    "ontag":    { "locked": { "type": "github", "owner": "o", "repo": "t", "rev": "t0" },
                  "original": { "type": "github", "owner": "o", "repo": "t", "ref": "v1.0" } },
    "pinned":   { "locked": { "type": "github", "owner": "o", "repo": "p", "rev": "p0" },
                  "original": { "type": "github", "owner": "o", "repo": "p", "rev": "p0" } },
    "tarball-input": { "locked": { "type": "tarball", "url": "https://example/x.tar.gz" },
                  "original": { "type": "tarball", "url": "https://example/x.tar.gz" } }
  },
  "root": "root",
  "version": 7
}
EOF

bash "$WATCH" candidates --lock "$T/flake.lock" >"$T/candidates.json"
eq "candidates: github ref-following root inputs only, sorted" \
    "onbranch ondefault ontag" "$(jq -r '[.[].input] | join(" ")' "$T/candidates.json")"
eq "candidates: default branch has a null ref" \
    "null" "$(jq -c '.[] | select(.input == "ondefault") | .ref' "$T/candidates.json")"

# ---------------------------------------------------------------------------
# resolve-heads (fake git)
# ---------------------------------------------------------------------------

# The interpreter is bash's absolute path, not /usr/bin/env: the flake
# check's build sandbox has no /usr/bin/env.
{
    printf '#!%s\n' "$(command -v bash)"
    cat <<'EOF'
# ls-remote <url> <refs...>
url="$2"
case "$url" in
  */o/b) printf 'b1\trefs/heads/main\n' ;;
  */o/d) printf 'd1\tHEAD\n' ;;
  */o/t) printf 't9\trefs/tags/v1.0\n' ;;
  */o/both) printf 'br\trefs/heads/v2\ntg\trefs/tags/v2\n' ;;
  */o/gone) exit 0 ;;
  */o/down) echo "fatal: unable to access" >&2; exit 128 ;;
esac
EOF
} >"$T/fake-git"
chmod +x "$T/fake-git"

jq '. + [
  {input: "both", owner: "o", repo: "both", ref: "v2", locked_rev: "x"},
  {input: "gone", owner: "o", repo: "gone", ref: "main", locked_rev: "x"},
  {input: "down", owner: "o", repo: "down", ref: null, locked_rev: "x"}
]' "$T/candidates.json" >"$T/candidates-more.json"

FLAKE_WATCH_GIT="$T/fake-git" FLAKE_WATCH_JOBS=2 \
    bash "$WATCH" resolve-heads --candidates "$T/candidates-more.json" >"$T/heads.json" 2>"$T/heads.err"
eq "resolve-heads: tag-only refs, missing refs and failed lookups are dropped, order kept" \
    "onbranch ondefault both" "$(jq -r '[.[].input] | join(" ")' "$T/heads.json")"
eq "resolve-heads: branch head" "b1" "$(jq -r '.[] | select(.input == "onbranch") | .upstream_rev' "$T/heads.json")"
eq "resolve-heads: default branch via HEAD" "d1" "$(jq -r '.[] | select(.input == "ondefault") | .upstream_rev' "$T/heads.json")"
eq "resolve-heads: a branch wins over a same-named tag" \
    "br" "$(jq -r '.[] | select(.input == "both") | .upstream_rev' "$T/heads.json")"
has "resolve-heads: tag reported" "ontag: pinned to tag v1.0" "$(cat "$T/heads.err")"
has "resolve-heads: failed lookup warned" "down: git ls-remote" "$(cat "$T/heads.err")"

# ---------------------------------------------------------------------------
# plan
# ---------------------------------------------------------------------------

cat >"$T/heads-plan.json" <<'EOF'
[
  { "input": "a", "upstream_rev": "a1", "locked_rev": "a0" },
  { "input": "b", "upstream_rev": "b1", "locked_rev": "b0" },
  { "input": "c", "upstream_rev": "c1", "locked_rev": "c0" },
  { "input": "d", "upstream_rev": "d0", "locked_rev": "d0" },
  { "input": "e", "upstream_rev": "e2", "locked_rev": "e0" }
]
EOF
echo '["c"]' >"$T/prs.json"
cat >"$T/prev.json" <<'EOF'
{ "version": 1, "inputs": {
  "b": { "kinds": { "linux": "rebuild" }, "upstream_rev": "b1", "locked_rev": "b0", "classified_at": "t0" },
  "e": { "kinds": { "linux": "none", "darwin": "none" }, "upstream_rev": "e1", "locked_rev": "e0", "classified_at": "t0" }
} }
EOF
bash "$WATCH" plan --heads "$T/heads-plan.json" --open-prs "$T/prs.json" --previous "$T/prev.json" >"$T/plan.json"
eq "plan: up-to-date inputs are not moved" "a b c e" "$(jq -r '[.moved[].input] | join(" ")' "$T/plan.json")"
eq "plan: open PR recorded" "true" "$(jq -r '.moved[] | select(.input == "c") | .pr_open' "$T/plan.json")"
eq "plan linux: new, PR-free inputs and moved-again ones; a known kind is reused" \
    "a e" "$(jq -r '.classify.linux | join(" ")' "$T/plan.json")"
eq "plan darwin: a missing OS kind is asked for again" \
    "a b e" "$(jq -r '.classify.darwin | join(" ")' "$T/plan.json")"

echo '{}' >"$T/empty.json"
bash "$WATCH" plan --heads "$T/heads-plan.json" --open-prs "$T/prs.json" --previous "$T/empty.json" >"$T/plan-first.json"
eq "plan: no previous status file classifies everything moved without a PR" \
    "a b e" "$(jq -r '.classify.linux | join(" ")' "$T/plan-first.json")"

# ---------------------------------------------------------------------------
# merge
# ---------------------------------------------------------------------------

cat >"$T/policy.json" <<'EOF'
{ "version": 1, "defaults": { "policy": "auto", "max_age_days": 7 },
  "inputs": { "e": { "policy": "manual" } } }
EOF
echo '{"a": "source", "e": "source"}' >"$T/lin.json"
echo '{"b": "source"}' >"$T/dar.json"
bash "$WATCH" merge --plan "$T/plan.json" --previous "$T/prev.json" --policy "$T/policy.json" \
    --linux "$T/lin.json" --darwin "$T/dar.json" --now t1 >"$T/merged.json"

eq "merge: status keeps moved, classified inputs (PR-open c has no prior entry)" \
    "a b e" "$(jq -r '.status.inputs | keys | join(" ")' "$T/merged.json")"
eq "merge: a fresh OS result joins the reused one" \
    '{"darwin":"source","linux":"rebuild"}' "$(jq -cS '.status.inputs.b.kinds' "$T/merged.json")"
eq "merge: kinds from an older upstream revision are dropped" \
    '{"linux":"source"}' "$(jq -cS '.status.inputs.e.kinds' "$T/merged.json")"
eq "merge: revisions recorded" "e2 e0" "$(jq -r '.status.inputs.e | "\(.upstream_rev) \(.locked_rev)"' "$T/merged.json")"
eq "merge: fresh entries are stamped" "t1" "$(jq -r '.status.inputs.a.classified_at' "$T/merged.json")"
eq "merge: source under auto is dispatched, under manual it is not" \
    '["a","b"]' "$(jq -c '.dispatch' "$T/merged.json")"
eq "merge: status version" "1" "$(jq -r '.status.version' "$T/merged.json")"

# The next hour, nothing moved: same file, nothing dispatched again.
jq .status "$T/merged.json" >"$T/prev2.json"
bash "$WATCH" plan --heads "$T/heads-plan.json" --open-prs "$T/prs.json" --previous "$T/prev2.json" >"$T/plan2.json"
eq "plan, second hour: only the missing darwin kinds" "" "$(jq -r '.classify.linux | join(" ")' "$T/plan2.json")"
bash "$WATCH" merge --plan "$T/plan2.json" --previous "$T/prev2.json" --policy "$T/policy.json" \
    --linux "$T/empty.json" --darwin "$T/empty.json" --now t2 >"$T/merged2.json"
eq "merge, second hour: byte-identical status" \
    "$(jq -S .status "$T/merged.json")" "$(jq -S .status "$T/merged2.json")"
eq "merge, second hour: no repeat dispatch" "[]" "$(jq -c '.dispatch' "$T/merged2.json")"

# A source result arriving later for an input already known to be source
# for the same revision is not dispatched twice.
echo '{"a": "source"}' >"$T/dar-a.json"
bash "$WATCH" merge --plan "$T/plan2.json" --previous "$T/prev2.json" --policy "$T/policy.json" \
    --linux "$T/empty.json" --darwin "$T/dar-a.json" --now t3 >"$T/merged3.json"
eq "merge: a second OS's source result does not re-dispatch" "[]" "$(jq -c '.dispatch' "$T/merged3.json")"

# An open PR carries the previous entry unchanged and never dispatches.
echo '["a"]' >"$T/prs-a.json"
bash "$WATCH" plan --heads "$T/heads-plan.json" --open-prs "$T/prs-a.json" --previous "$T/prev2.json" >"$T/plan4.json"
bash "$WATCH" merge --plan "$T/plan4.json" --previous "$T/prev2.json" --policy "$T/policy.json" \
    --linux "$T/empty.json" --darwin "$T/empty.json" --now t4 >"$T/merged4.json"
eq "merge: PR-open input keeps its entry" \
    "$(jq -c '.inputs.a' "$T/prev2.json")" "$(jq -c '.status.inputs.a' "$T/merged4.json")"

# An input that caught up disappears from the status.
jq '[.[] | if .input == "a" then .locked_rev = .upstream_rev else . end]' "$T/heads-plan.json" >"$T/heads-caught.json"
bash "$WATCH" plan --heads "$T/heads-caught.json" --open-prs "$T/prs.json" --previous "$T/prev2.json" >"$T/plan5.json"
bash "$WATCH" merge --plan "$T/plan5.json" --previous "$T/prev2.json" --policy "$T/policy.json" \
    --linux "$T/empty.json" --darwin "$T/empty.json" --now t5 >"$T/merged5.json"
eq "merge: a caught-up input is dropped" "false" "$(jq '.status.inputs | has("a")' "$T/merged5.json")"

set +e
OUT="$(bash "$WATCH" merge --plan "$T/plan.json" 2>&1)"
RC=$?
set -e
eq "merge: missing arguments are a usage error" 2 "$RC"
has "merge: names the missing flag" "requires --previous" "$OUT"

# ---------------------------------------------------------------------------
# publish (local bare repository)
# ---------------------------------------------------------------------------

git init -q --bare "$T/remote.git"
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --file "$T/gitconfig" init.defaultBranch main
pub() {
    FLAKE_WATCH_REMOTE="$T/remote.git" GH_TOKEN=unused REPO=o/r bash "$PUBLISH" "$1" 2>&1
}
commits() { git --git-dir="$T/remote.git" rev-list --count flake-watch 2>/dev/null || echo 0; }

jq -S .status "$T/merged.json" >"$T/status1.json"
has "publish: creates the branch" "creating it as an orphan" "$(pub "$T/status1.json")"
eq "publish: one commit" 1 "$(commits)"
eq "publish: file content" "$(cat "$T/status1.json")" \
    "$(git --git-dir="$T/remote.git" show flake-watch:status/flake-inputs.json)"
eq "publish: orphan holds only the README and the status file" "README.md status/flake-inputs.json" \
    "$(git --git-dir="$T/remote.git" ls-tree -r --name-only flake-watch | tr '\n' ' ' | sed 's/ $//')"
has "publish: unchanged content commits nothing" "unchanged" "$(pub "$T/status1.json")"
eq "publish: still one commit" 1 "$(commits)"
jq -S .status "$T/merged5.json" >"$T/status2.json"
has "publish: changed content is pushed" "published" "$(pub "$T/status2.json")"
eq "publish: two commits" 2 "$(commits)"

# ---------------------------------------------------------------------------
# check-flake-input-policy
# ---------------------------------------------------------------------------

policy_run() { # policy-json -> PRC (exit code), POUT (output)
    printf '%s' "$1" >"$T/p.json"
    set +e
    POUT="$(bash "$POLICY_CHECK" "$T/p.json" "$T/flake.lock" 2>&1)"
    PRC=$?
    set -e
}
policy_run '{"version":1,"defaults":{"policy":"auto","max_age_days":7},"inputs":{"onbranch":{"policy":"manual"}}}'
eq "policy: valid" 0 "$PRC"
policy_run '{"version":1,"defaults":{"policy":"auto","max_age_days":7},"inputs":{"nope":{"policy":"manual"}}}'
eq "policy: unknown input" 1 "$PRC"
has "policy: names the unknown input" "inputs.nope: not a root input" "$POUT"
policy_run '{"version":1,"defaults":{"policy":"sometimes","max_age_days":7}}'
eq "policy: bad policy value" 1 "$PRC"
policy_run '{"version":1,"defaults":{"policy":"auto","max_age_days":1.5}}'
eq "policy: non-integer max age" 1 "$PRC"
policy_run '{"version":1,"defaults":{"policy":"auto"}}'
eq "policy: defaults must be complete" 1 "$PRC"
policy_run '{"version":1,"defaults":{"policy":"auto","max_age_days":7},"inputs":{"onbranch":{"mode":"manual"}}}'
eq "policy: unknown key" 1 "$PRC"
has "policy: names the unknown key" "inputs.onbranch: unknown key mode" "$POUT"
policy_run '{"version":2,"defaults":{"policy":"auto","max_age_days":7}}'
eq "policy: wrong version" 1 "$PRC"
policy_run '{'
eq "policy: not JSON" 1 "$PRC"

set +e
OUT="$(cd "$ROOT" && bash "$POLICY_CHECK" 2>&1)"
RC=$?
set -e
eq "policy: the repo's own policy file is valid" 0 "$RC"
[[ $RC -eq 0 ]] || printf '%s\n' "$OUT" >&2

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
