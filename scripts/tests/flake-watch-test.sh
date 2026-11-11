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

# Run from a git hook (pre-commit at `git commit` time), git exports
# GIT_INDEX_FILE, GIT_DIR and friends. Left set, every git command below
# would act on the repository being committed instead of the scratch ones
# this suite creates -- it once rewrote the real index as a mass deletion.
# (env + sed, not compgen: Nix's minimal bash has no compgen.)
for var in $(env | sed -n 's/^\(GIT_[A-Za-z0-9_]*\)=.*/\1/p'); do
    unset "$var"
done

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
eq "resolve-heads: tag-only and missing refs are dropped, order kept" \
    "onbranch ondefault both down" "$(jq -r '[.[].input] | join(" ")' "$T/heads.json")"
eq "resolve-heads: a failed lookup is kept, marked unresolved, with no head" \
    "true null" "$(jq -r '.[] | select(.input == "down") | "\(.unresolved) \(.upstream_rev)"' "$T/heads.json")"
eq "resolve-heads: branch head" "b1" "$(jq -r '.[] | select(.input == "onbranch") | .upstream_rev' "$T/heads.json")"
eq "resolve-heads: default branch via HEAD" "d1" "$(jq -r '.[] | select(.input == "ondefault") | .upstream_rev' "$T/heads.json")"
eq "resolve-heads: a branch wins over a same-named tag" \
    "br" "$(jq -r '.[] | select(.input == "both") | .upstream_rev' "$T/heads.json")"
has "resolve-heads: tag reported" "ontag: pinned to tag v1.0" "$(cat "$T/heads.err")"
has "resolve-heads: failed lookup warned" "down: git ls-remote" "$(cat "$T/heads.err")"

# ---------------------------------------------------------------------------
# plan
# ---------------------------------------------------------------------------

PLAN_AT="2026-11-11T11:00:00Z"

cat >"$T/heads-plan.json" <<'EOF'
[
  { "input": "a", "upstream_rev": "a1", "locked_rev": "a0" },
  { "input": "b", "upstream_rev": "b1", "locked_rev": "b0" },
  { "input": "c", "upstream_rev": "c1", "locked_rev": "c0" },
  { "input": "d", "upstream_rev": "d0", "locked_rev": "d0" },
  { "input": "e", "upstream_rev": "e2", "locked_rev": "e0" },
  { "input": "u", "locked_rev": "u0", "unresolved": true }
]
EOF
echo '["c"]' >"$T/prs.json"
cat >"$T/prev.json" <<'EOF'
{ "version": 1, "inputs": {
  "b": { "kinds": { "linux": "rebuild" }, "upstream_rev": "b1", "locked_rev": "b0", "classified_at": "2026-11-11T00:00:00Z" },
  "e": { "kinds": { "linux": "none", "darwin": "none" }, "upstream_rev": "e1", "locked_rev": "e0", "classified_at": "2026-11-11T00:00:00Z" },
  "u": { "kinds": { "linux": "source" }, "upstream_rev": "u1", "locked_rev": "u0", "classified_at": "2026-11-11T00:00:00Z" }
} }
EOF
bash "$WATCH" plan --heads "$T/heads-plan.json" --open-prs "$T/prs.json" --previous "$T/prev.json" --now "$PLAN_AT" >"$T/plan.json"
eq "plan: up-to-date and unresolved inputs are not moved" "a b c e" "$(jq -r '[.moved[].input] | join(" ")' "$T/plan.json")"
eq "plan: unresolved inputs listed" '["u"]' "$(jq -c '.unresolved' "$T/plan.json")"
eq "plan: open PR recorded" "true" "$(jq -r '.moved[] | select(.input == "c") | .pr_open' "$T/plan.json")"
eq "plan linux: new, PR-free inputs and moved-again ones; a known kind is reused" \
    "a e" "$(jq -r '[.classify.linux[].input] | join(" ")' "$T/plan.json")"
eq "plan: each classify entry carries the revisions it is planned for" \
    '{"input":"e","upstream_rev":"e2","locked_rev":"e0"}' "$(jq -c '.classify.linux[1]' "$T/plan.json")"
eq "plan darwin: a missing OS kind is asked for again" \
    "a b e" "$(jq -r '[.classify.darwin[].input] | join(" ")' "$T/plan.json")"

echo '{}' >"$T/empty.json"
bash "$WATCH" plan --heads "$T/heads-plan.json" --open-prs "$T/prs.json" --previous "$T/empty.json" --now "$PLAN_AT" >"$T/plan-first.json"
eq "plan: no previous status file classifies everything moved without a PR" \
    "a b e" "$(jq -r '[.classify.linux[].input] | join(" ")' "$T/plan-first.json")"

# ---------------------------------------------------------------------------
# merge and mark-dispatched
# ---------------------------------------------------------------------------

NOW="2026-11-11T12:00:00Z"
cat >"$T/policy.json" <<'EOF'
{ "version": 1, "defaults": { "policy": "auto", "max_age_days": 7 },
  "inputs": { "e": { "policy": "manual" } } }
EOF
merge() { # plan previous linux darwin now
    bash "$WATCH" merge --plan "$1" --previous "$2" --policy "$T/policy.json" \
        --linux "$3" --darwin "$4" --now "$5"
}
echo '{"a": "source", "e": "source"}' >"$T/lin.json"
echo '{"b": "source"}' >"$T/dar.json"
merge "$T/plan.json" "$T/prev.json" "$T/lin.json" "$T/dar.json" "$NOW" >"$T/merged.json"

eq "merge: status keeps moved, classified inputs and the unresolved one (PR-open c has no entry)" \
    "a b e u" "$(jq -r '.status.inputs | keys | join(" ")' "$T/merged.json")"
eq "merge: an unresolved input's entry is carried unchanged" \
    "$(jq -c '.inputs.u' "$T/prev.json")" "$(jq -c '.status.inputs.u' "$T/merged.json")"
eq "merge: a fresh OS result joins the reused one" \
    '{"darwin":"source","linux":"rebuild"}' "$(jq -cS '.status.inputs.b.kinds' "$T/merged.json")"
eq "merge: kinds from an older upstream revision are dropped" \
    '{"linux":"source"}' "$(jq -cS '.status.inputs.e.kinds' "$T/merged.json")"
eq "merge: revisions recorded" "e2 e0" "$(jq -r '.status.inputs.e | "\(.upstream_rev) \(.locked_rev)"' "$T/merged.json")"
eq "merge: fresh entries are stamped" "$NOW" "$(jq -r '.status.inputs.a.classified_at' "$T/merged.json")"
eq "merge: source under auto is dispatched, under manual it is not" \
    '["a","b"]' "$(jq -c '.dispatch' "$T/merged.json")"
eq "merge: status version" "1" "$(jq -r '.status.version' "$T/merged.json")"

# A dispatch that never succeeded is not recorded, so it is asked for again.
jq .status "$T/merged.json" >"$T/prev-undispatched.json"
bash "$WATCH" plan --heads "$T/heads-plan.json" --open-prs "$T/prs.json" --previous "$T/prev-undispatched.json" --now "$PLAN_AT" >"$T/plan2.json"
merge "$T/plan2.json" "$T/prev-undispatched.json" "$T/empty.json" "$T/empty.json" "2026-11-11T13:00:00Z" >"$T/merged-retry.json"
eq "merge: an unrecorded dispatch is asked for again" '["a","b"]' "$(jq -c '.dispatch' "$T/merged-retry.json")"

# Once recorded, the same revision is not dispatched again...
echo '["a","b"]' >"$T/done.json"
bash "$WATCH" mark-dispatched --status "$T/prev-undispatched.json" --inputs "$T/done.json" --now "$NOW" >"$T/prev2.json"
eq "mark-dispatched: records the dispatched revision and time" \
    "a1 $NOW" "$(jq -r '.inputs.a | "\(.dispatched_rev) \(.dispatched_at)"' "$T/prev2.json")"
eq "mark-dispatched: leaves other inputs alone" "false" "$(jq '.inputs.e | has("dispatched_rev")' "$T/prev2.json")"

bash "$WATCH" plan --heads "$T/heads-plan.json" --open-prs "$T/prs.json" --previous "$T/prev2.json" --now "$PLAN_AT" >"$T/plan3.json"
eq "plan, next hour: nothing to classify on Linux" "" "$(jq -r '[.classify.linux[].input] | join(" ")' "$T/plan3.json")"
merge "$T/plan3.json" "$T/prev2.json" "$T/empty.json" "$T/empty.json" "2026-11-11T13:00:00Z" >"$T/merged3.json"
eq "merge, next hour: byte-identical status" "$(jq -S . "$T/prev2.json")" "$(jq -S .status "$T/merged3.json")"
eq "merge, next hour: no repeat dispatch" "[]" "$(jq -c '.dispatch' "$T/merged3.json")"

echo '{"a": "source"}' >"$T/dar-a.json"
merge "$T/plan3.json" "$T/prev2.json" "$T/empty.json" "$T/dar-a.json" "2026-11-11T13:00:00Z" >"$T/merged4.json"
eq "merge: a second OS's source result does not re-dispatch" "[]" "$(jq -c '.dispatch' "$T/merged4.json")"
eq "merge: ...and keeps the dispatch record" "a1" "$(jq -r '.status.inputs.a.dispatched_rev' "$T/merged4.json")"

# ...until the retry interval passes with still no update PR.
merge "$T/plan3.json" "$T/prev2.json" "$T/empty.json" "$T/empty.json" "2026-11-11T18:00:00Z" >"$T/merged5.json"
eq "merge: dispatched 6h ago with no PR: dispatched again" '["a","b"]' "$(jq -c '.dispatch' "$T/merged5.json")"

# A new upstream revision drops the old dispatch record.
jq '[.[] | if .input == "a" then .upstream_rev = "a2" else . end]' "$T/heads-plan.json" >"$T/heads-a2.json"
bash "$WATCH" plan --heads "$T/heads-a2.json" --open-prs "$T/prs.json" --previous "$T/prev2.json" --now "$PLAN_AT" >"$T/plan6.json"
echo '{"a": "source"}' >"$T/lin-a.json"
merge "$T/plan6.json" "$T/prev2.json" "$T/lin-a.json" "$T/empty.json" "2026-11-11T13:00:00Z" >"$T/merged6.json"
eq "merge: a new upstream revision is dispatched" '["a"]' "$(jq -c '.dispatch' "$T/merged6.json")"
eq "merge: ...without the old record" "false" "$(jq '.status.inputs.a | has("dispatched_rev")' "$T/merged6.json")"

# An open PR carries the previous entry unchanged and never dispatches.
echo '["a"]' >"$T/prs-a.json"
bash "$WATCH" plan --heads "$T/heads-plan.json" --open-prs "$T/prs-a.json" --previous "$T/prev2.json" --now "$PLAN_AT" >"$T/plan7.json"
merge "$T/plan7.json" "$T/prev2.json" "$T/empty.json" "$T/empty.json" "2026-11-11T18:00:00Z" >"$T/merged7.json"
eq "merge: PR-open input keeps its entry" "$(jq -c '.inputs.a' "$T/prev2.json")" "$(jq -c '.status.inputs.a' "$T/merged7.json")"
eq "merge: PR-open input is not dispatched" '["b"]' "$(jq -c '.dispatch' "$T/merged7.json")"

# An input that caught up disappears from the status.
jq '[.[] | if .input == "a" then .locked_rev = .upstream_rev else . end]' "$T/heads-plan.json" >"$T/heads-caught.json"
bash "$WATCH" plan --heads "$T/heads-caught.json" --open-prs "$T/prs.json" --previous "$T/prev2.json" --now "$PLAN_AT" >"$T/plan8.json"
merge "$T/plan8.json" "$T/prev2.json" "$T/empty.json" "$T/empty.json" "2026-11-11T13:00:00Z" >"$T/merged8.json"
eq "merge: a caught-up input is dropped" "false" "$(jq '.status.inputs | has("a")' "$T/merged8.json")"

# A publication from an older plan (a classify job finishing after the next
# hour already published) never overwrites the newer status.
jq '.planned_at = "2026-11-11T09:00:00Z"' "$T/plan3.json" >"$T/plan-old.json"
jq '. + {planned_at: "2026-11-11T12:00:00Z", inputs: (.inputs + {
      z: { kinds: { linux: "rebuild" }, upstream_rev: "z1", locked_rev: "z0", classified_at: "t" } })}' \
    "$T/prev2.json" >"$T/prev-newer.json"
echo '{"a": "rebuild", "b": "none"}' >"$T/dar-old.json"
jq '.moved |= map(if .input == "b" then .upstream_rev = "b-old" else . end)' "$T/plan-old.json" >"$T/plan-old-b.json"
merge "$T/plan-old-b.json" "$T/prev-newer.json" "$T/empty.json" "$T/dar-old.json" "2026-11-11T13:00:00Z" >"$T/merged-stale.json"
eq "merge, stale plan: nothing dispatched" "[]" "$(jq -c '.dispatch' "$T/merged-stale.json")"
eq "merge, stale plan: an entry the old plan does not know is kept" \
    "$(jq -c '.inputs.z' "$T/prev-newer.json")" "$(jq -c '.status.inputs.z' "$T/merged-stale.json")"
eq "merge, stale plan: a result for revisions the entry still has is added" \
    '{"darwin":"rebuild","linux":"source"}' "$(jq -cS '.status.inputs.a.kinds' "$T/merged-stale.json")"
eq "merge, stale plan: a result for older revisions is not" \
    "$(jq -c '.inputs.b' "$T/prev-newer.json")" "$(jq -c '.status.inputs.b' "$T/merged-stale.json")"
eq "merge, stale plan: planned_at does not go backwards" \
    "2026-11-11T12:00:00Z" "$(jq -r '.status.planned_at' "$T/merged-stale.json")"
eq "merge: a current plan records its planned_at" "$PLAN_AT" "$(jq -r '.status.planned_at' "$T/merged.json")"

set +e
OUT="$(bash "$WATCH" merge --plan "$T/plan.json" 2>&1)"
RC=$?
set -e
eq "merge: missing arguments are a usage error" 2 "$RC"
has "merge: names the missing flag" "requires --previous" "$OUT"

# ---------------------------------------------------------------------------
# publish (local bare repository, fake gh)
# ---------------------------------------------------------------------------

git init -q --bare "$T/remote.git"
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --file "$T/gitconfig" init.defaultBranch main

{
    printf '#!%s\n' "$(command -v bash)"
    cat <<EOF
# gh workflow run update-flakes.yaml ... -f single_input=<input>
for arg in "\$@"; do
  case "\$arg" in single_input=*) input="\${arg#single_input=}" ;; esac
done
echo "\$input" >> "$T/gh.log"
[[ "\$input" != "\$(cat "$T/gh-fail" 2>/dev/null)" ]]
EOF
} >"$T/fake-gh"
chmod +x "$T/fake-gh"

pub() { # linux darwin
    FLAKE_WATCH_REMOTE="$T/remote.git" FLAKE_WATCH_GH="$T/fake-gh" GH_TOKEN=unused REPO=o/r \
        bash "$PUBLISH" "$T/plan.json" "$T/policy.json" "$1" "$2" 2>&1
}
commits() { git --git-dir="$T/remote.git" rev-list --count flake-watch 2>/dev/null || echo 0; }
published() { git --git-dir="$T/remote.git" show flake-watch:status/flake-inputs.json; }

echo "b" >"$T/gh-fail"
has "publish: creates the branch" "creating it as an orphan" "$(pub "$T/lin.json" "$T/empty.json")"
eq "publish: one commit" 1 "$(commits)"
eq "publish: orphan holds only the README and the status file" "README.md status/flake-inputs.json" \
    "$(git --git-dir="$T/remote.git" ls-tree -r --name-only flake-watch | tr '\n' ' ' | sed 's/ $//')"
eq "publish: the linux results are published" '{"linux":"source"}' "$(published | jq -c '.inputs.a.kinds')"
eq "publish: dispatched a (b has no source result yet)" "a" "$(tr '\n' ' ' <"$T/gh.log" | sed 's/ $//')"
eq "publish: a successful dispatch is recorded" "a1" "$(published | jq -r '.inputs.a.dispatched_rev')"

# The darwin job publishes later against the latest file: both OSes' results
# end up in it, a is not dispatched again, and b's failing dispatch is not
# recorded.
: >"$T/gh.log"
has "publish: second job" "published" "$(pub "$T/empty.json" "$T/dar.json")"
eq "publish: the darwin results are published" '{"darwin":"source"}' "$(published | jq -cS '.inputs.b.kinds')"
eq "publish: linux results survive the darwin publish" '{"linux":"source"}' "$(published | jq -c '.inputs.a.kinds')"
eq "publish: only b dispatched" "b" "$(tr '\n' ' ' <"$T/gh.log" | sed 's/ $//')"
eq "publish: a failed dispatch is not recorded" "false" "$(published | jq '.inputs.b | has("dispatched_rev")')"

# Next hour, b's dispatch works.
: >"$T/gh.log"
rm "$T/gh-fail"
pub "$T/empty.json" "$T/empty.json" >/dev/null
eq "publish: the failed dispatch is retried" "b" "$(tr '\n' ' ' <"$T/gh.log" | sed 's/ $//')"
eq "publish: and recorded once it works" "b1" "$(published | jq -r '.inputs.b.dispatched_rev')"

: >"$T/gh.log"
before="$(commits)"
has "publish: nothing new commits nothing" "unchanged" "$(pub "$T/empty.json" "$T/empty.json")"
eq "publish: commit count unchanged" "$before" "$(commits)"
eq "publish: nothing dispatched" "" "$(cat "$T/gh.log")"

# ---------------------------------------------------------------------------
# classify (fake scripts/flake-input-impact.sh)
# ---------------------------------------------------------------------------

CLASSIFY="$ROOT/.github/scripts/flake-watch-classify.sh"
mkdir -p "$T/classify/scripts"
{
    printf '#!%s\n' "$(command -v bash)"
    cat <<'EOF'
# --os OS --json INPUT; "moved" reports a newer revision than planned.
input="${!#}"
case "$input" in
  ok) echo '{"input":"ok","kind":"source","rev":"r1","changed":[]}' ;;
  moved) echo '{"input":"moved","kind":"none","rev":"r9","changed":[]}' ;;
  broken) exit 1 ;;
esac
EOF
} >"$T/classify/scripts/flake-input-impact.sh"
chmod +x "$T/classify/scripts/flake-input-impact.sh"

set +e
OUT="$(cd "$T/classify" && INPUTS='[{"input":"ok","upstream_rev":"r1"},{"input":"moved","upstream_rev":"r2"},{"input":"broken","upstream_rev":"r3"}]' \
    bash "$CLASSIFY" linux 2>&1)"
RC=$?
set -e
eq "classify: a result for the planned revision is kept; a moved or failed one is not" \
    '{"ok":"source"}' "$(jq -c . "$T/classify/impact-linux.json")"
has "classify: says the input moved since planning" "moved moved again since planning" "$OUT"
eq "classify: a failed input fails the step, after writing the results" 1 "$RC"

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
