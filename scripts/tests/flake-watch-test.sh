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
eq "plan linux: every moved input without an update PR is a candidate" \
    "a b e" "$(jq -r '[.classify.linux[].input] | join(" ")' "$T/plan.json")"
eq "plan: a candidate carries its planned revisions; nothing cached for a moved-again input" \
    '{"input":"e","upstream_rev":"e2","locked_rev":"e0","cached_kind":null,"cached_base":null}' \
    "$(jq -c '.classify.linux[] | select(.input == "e")' "$T/plan.json")"
eq "plan: a kind for the same revisions is offered as cached (with its base, none here)" \
    '"rebuild" null' "$(jq -r '.classify.linux[] | select(.input == "b") | "\(.cached_kind | tojson) \(.cached_base | tojson)"' "$T/plan.json")"
eq "plan darwin: same candidates, nothing cached for b on darwin" \
    "a b e null" "$(jq -r '([.classify.darwin[].input] | join(" ")) + " " + (.classify.darwin[] | select(.input == "b") | .cached_kind | tojson)' "$T/plan.json")"

# summary is what the workflow logs; it must accept the plan's real shape.
set +e
SUMMARY="$(bash "$WATCH" summary --plan "$T/plan.json" 2>&1)"
RC=$?
set -e
eq "summary: succeeds on a real plan" 0 "$RC"
has "summary: lists the moved inputs" "moved: a, b, c, e" "$SUMMARY"
has "summary: lists the unresolved inputs" "unresolved: u" "$SUMMARY"
has "summary: lists linux classification by name" "classify (linux): a, b, e" "$SUMMARY"
has "summary: lists darwin classification by name" "classify (darwin): a, b, e" "$SUMMARY"

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
echo '{"base": "B1", "kinds": {"a": "source", "e": "source"}}' >"$T/lin.json"
echo '{"base": "B1", "kinds": {"b": "source"}}' >"$T/dar.json"
merge "$T/plan.json" "$T/prev.json" "$T/lin.json" "$T/dar.json" "$NOW" >"$T/merged.json"

eq "merge: status keeps moved, classified inputs and the unresolved one (PR-open c has no entry)" \
    "a b e u" "$(jq -r '.status.inputs | keys | join(" ")' "$T/merged.json")"
eq "merge: an unresolved input's entry is carried unchanged" \
    "$(jq -c '.inputs.u' "$T/prev.json")" "$(jq -c '.status.inputs.u' "$T/merged.json")"
eq "merge: a cached kind with no recorded base is dropped once a base is known (asked again)" \
    '{"darwin":"source"}' "$(jq -cS '.status.inputs.b.kinds' "$T/merged.json")"
eq "merge: kinds from an older upstream revision are dropped" \
    '{"linux":"source"}' "$(jq -cS '.status.inputs.e.kinds' "$T/merged.json")"
eq "merge: revisions recorded" "e2 e0" "$(jq -r '.status.inputs.e | "\(.upstream_rev) \(.locked_rev)"' "$T/merged.json")"
eq "merge: fresh entries are stamped" "$NOW" "$(jq -r '.status.inputs.a.classified_at' "$T/merged.json")"
eq "merge: source under auto is dispatched, under manual it is not" \
    '["a","b"]' "$(jq -c '.dispatch' "$T/merged.json")"
eq "merge: status version" "1" "$(jq -r '.status.version' "$T/merged.json")"

# A renovate-policy input is never dispatched to update-flakes.yaml either.
cp "$T/policy.json" "$T/policy-auto-manual.json"
jq '.inputs.a.policy = "renovate"' "$T/policy-auto-manual.json" >"$T/policy.json"
merge "$T/plan.json" "$T/prev.json" "$T/lin.json" "$T/dar.json" "$NOW" >"$T/merged-renovate.json"
eq "merge: source under renovate is not dispatched" '["b"]' "$(jq -c '.dispatch' "$T/merged-renovate.json")"
cp "$T/policy-auto-manual.json" "$T/policy.json"

# A dispatch that never succeeded is not recorded, so it is asked for again.
jq .status "$T/merged.json" >"$T/prev-undispatched.json"
bash "$WATCH" plan --heads "$T/heads-plan.json" --open-prs "$T/prs.json" --previous "$T/prev-undispatched.json" --now "$PLAN_AT" >"$T/plan2.json"
merge "$T/plan2.json" "$T/prev-undispatched.json" "$T/empty.json" "$T/empty.json" "2026-11-11T13:00:00Z" >"$T/merged-retry.json"
eq "merge: an unrecorded dispatch is asked for again" '["a","b"]' "$(jq -c '.dispatch' "$T/merged-retry.json")"

# Once recorded, the same revision is not dispatched again...
echo '[{"input":"a","rev":"a1"},{"input":"b","rev":"b1"}]' >"$T/done.json"
bash "$WATCH" mark-dispatched --status "$T/prev-undispatched.json" --inputs "$T/done.json" --now "$NOW" >"$T/prev2.json"
eq "mark-dispatched: records the dispatched revision and time" \
    "a1 $NOW" "$(jq -r '.inputs.a | "\(.dispatched_rev) \(.dispatched_at)"' "$T/prev2.json")"
eq "mark-dispatched: leaves other inputs alone" "false" "$(jq '.inputs.e | has("dispatched_rev")' "$T/prev2.json")"
echo '[{"input":"a","rev":"a0-older"}]' >"$T/done-old.json"
eq "mark-dispatched: a dispatch of an older revision does not mark the current one" "false" \
    "$(bash "$WATCH" mark-dispatched --status "$T/prev-undispatched.json" --inputs "$T/done-old.json" --now "$NOW" | jq '.inputs.a | has("dispatched_rev")')"

bash "$WATCH" plan --heads "$T/heads-plan.json" --open-prs "$T/prs.json" --previous "$T/prev2.json" --now "$PLAN_AT" >"$T/plan3.json"
eq "plan, next hour: the cached kind comes with the base it was computed against" \
    "source B1" "$(jq -r '.classify.linux[] | select(.input == "a") | "\(.cached_kind) \(.cached_base)"' "$T/plan3.json")"
merge "$T/plan3.json" "$T/prev2.json" "$T/empty.json" "$T/empty.json" "2026-11-11T13:00:00Z" >"$T/merged3.json"
eq "merge, next hour: byte-identical status" "$(jq -S . "$T/prev2.json")" "$(jq -S .status "$T/merged3.json")"
eq "merge, next hour: no repeat dispatch" "[]" "$(jq -c '.dispatch' "$T/merged3.json")"

echo '{"base": "B1", "kinds": {"a": "source"}}' >"$T/dar-a.json"
merge "$T/plan3.json" "$T/prev2.json" "$T/empty.json" "$T/dar-a.json" "2026-11-11T13:00:00Z" >"$T/merged4.json"
eq "merge: a second OS's source result does not re-dispatch" "[]" "$(jq -c '.dispatch' "$T/merged4.json")"
eq "merge: ...and keeps the dispatch record" "a1" "$(jq -r '.status.inputs.a.dispatched_rev' "$T/merged4.json")"

# Base fingerprints: a classify job that saw the same base keeps cached
# kinds; one that saw a different base (main changed what it builds) drops
# them unless it reclassified; the find job (no base) keeps everything.
eq "merge: a fresh kind records its base" "B1" "$(jq -r '.status.inputs.a.bases.linux' "$T/merged.json")"
echo '{"base": "B1", "kinds": {}}' >"$T/lin-same.json"
merge "$T/plan3.json" "$T/prev2.json" "$T/lin-same.json" "$T/empty.json" "2026-11-11T13:00:00Z" >"$T/merged-same.json"
eq "merge: same base, no fresh result: the cached kind stays" "source" "$(jq -r '.status.inputs.a.kinds.linux' "$T/merged-same.json")"
eq "merge: ...and the status is unchanged" "$(jq -S . "$T/prev2.json")" "$(jq -S .status "$T/merged-same.json")"
echo '{"base": "B2", "kinds": {}}' >"$T/lin-new.json"
merge "$T/plan3.json" "$T/prev2.json" "$T/lin-new.json" "$T/empty.json" "2026-11-11T13:00:00Z" >"$T/merged-new.json"
eq "merge: a new base with no fresh result drops that OS's cached kind" "null" "$(jq -r '.status.inputs.a.kinds.linux' "$T/merged-new.json")"
eq "merge: ...but keeps the other OS's kind" "source" "$(jq -r '.status.inputs.b.kinds.darwin' "$T/merged-new.json")"
echo '{"base": "B2", "kinds": {"a": "none"}}' >"$T/lin-new-a.json"
merge "$T/plan3.json" "$T/prev2.json" "$T/lin-new-a.json" "$T/empty.json" "2026-11-11T13:00:00Z" >"$T/merged-new-a.json"
# Every cached kind invalidated, nothing fresh: the entry still keeps its
# dispatch record for this revision, so the dispatch is not repeated early.
echo '{"base": "B2", "kinds": {}}' >"$T/both-new.json"
merge "$T/plan3.json" "$T/prev2.json" "$T/both-new.json" "$T/both-new.json" "2026-11-11T13:00:00Z" >"$T/merged-none.json"
eq "merge: all kinds invalidated keeps the dispatch record" "a1 {}" \
    "$(jq -r '.status.inputs.a | "\(.dispatched_rev) \(.kinds | tojson)"' "$T/merged-none.json")"
eq "merge: ...and does not dispatch again" "[]" "$(jq -c '.dispatch' "$T/merged-none.json")"
eq "merge: a new base with a fresh result records both" "none B2" "$(jq -r '.status.inputs.a | "\(.kinds.linux) \(.bases.linux)"' "$T/merged-new-a.json")"

# ...until the retry interval passes with still no update PR.
merge "$T/plan3.json" "$T/prev2.json" "$T/empty.json" "$T/empty.json" "2026-11-11T18:00:00Z" >"$T/merged5.json"
eq "merge: dispatched 6h ago with no PR: dispatched again" '["a","b"]' "$(jq -c '.dispatch' "$T/merged5.json")"

# A new upstream revision drops the old dispatch record.
jq '[.[] | if .input == "a" then .upstream_rev = "a2" else . end]' "$T/heads-plan.json" >"$T/heads-a2.json"
bash "$WATCH" plan --heads "$T/heads-a2.json" --open-prs "$T/prs.json" --previous "$T/prev2.json" --now "$PLAN_AT" >"$T/plan6.json"
echo '{"base": "B1", "kinds": {"a": "source"}}' >"$T/lin-a.json"
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
echo '{"base": "B1", "kinds": {"a": "rebuild", "b": "none"}}' >"$T/dar-old.json"
jq '.moved |= map(if .input == "b" then .upstream_rev = "b-old" else . end)' "$T/plan-old.json" >"$T/plan-old-b.json"
merge "$T/plan-old-b.json" "$T/prev-newer.json" "$T/empty.json" "$T/dar-old.json" "2026-11-11T13:00:00Z" >"$T/merged-stale.json"
eq "merge, stale plan: nothing dispatched" "[]" "$(jq -c '.dispatch' "$T/merged-stale.json")"
eq "merge, stale plan: an entry the old plan does not know is kept" \
    "$(jq -c '.inputs.z' "$T/prev-newer.json")" "$(jq -c '.status.inputs.z' "$T/merged-stale.json")"
eq "merge, stale plan: even a result for revisions the entry still has is not added" \
    '{"linux":"source"}' "$(jq -cS '.status.inputs.a.kinds' "$T/merged-stale.json")"
eq "merge, stale plan: the status is left exactly as the newer run published it" \
    "$(jq -S . "$T/prev-newer.json")" "$(jq -S .status "$T/merged-stale.json")"
# A stale result for an OS the newer entry already classified does not
# replace it (prev-newer has a: linux=source; the stale job says rebuild).
echo '{"base": "B1", "kinds": {"a": "rebuild"}}' >"$T/lin-old.json"
merge "$T/plan-old-b.json" "$T/prev-newer.json" "$T/lin-old.json" "$T/empty.json" "2026-11-11T13:00:00Z" >"$T/merged-stale2.json"
eq "merge, stale plan: a newer kind for the same OS wins" "source" "$(jq -r '.status.inputs.a.kinds.linux' "$T/merged-stale2.json")"
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
# stale update PRs: pr-revs, plan, merge
# ---------------------------------------------------------------------------

# Fake gh: serves a flake.lock per update-<input> branch; "gone" has none.
{
    printf '#!%s\n' "$(command -v bash)"
    cat <<'EOF'
# api -H ... repos/o/r/contents/flake.lock?ref=update-<input>
url="${!#}"
case "$url" in
  *ref=update-stuck) echo '{"nodes":{"root":{"inputs":{"stuck":"stuck"}},"stuck":{"locked":{"rev":"s1"}}}}' ;;
  *ref=update-current) echo '{"nodes":{"root":{"inputs":{"current":"current"}},"current":{"locked":{"rev":"c2"}}}}' ;;
  *ref=update-manualpr) echo '{"nodes":{"root":{"inputs":{"manualpr":"manualpr"}},"manualpr":{"locked":{"rev":"m1"}}}}' ;;
  *) echo "HTTP 404" >&2; exit 1 ;;
esac
EOF
} >"$T/fake-gh-lock"
chmod +x "$T/fake-gh-lock"

echo '["stuck","current","manualpr","gone"]' >"$T/stale-prs.json"
FLAKE_WATCH_GH="$T/fake-gh-lock" REPO=o/r bash "$WATCH" pr-revs --open-prs "$T/stale-prs.json" >"$T/pr-revs.json" 2>"$T/pr-revs.err"
eq "pr-revs: each readable PR branch's locked revision; an unreadable one is left out" \
    '{"current":"c2","manualpr":"m1","stuck":"s1"}' "$(jq -cS . "$T/pr-revs.json")"
has "pr-revs: warns about the unreadable branch" "update-gone" "$(cat "$T/pr-revs.err")"

cat >"$T/heads-stale.json" <<'EOF'
[
  { "input": "stuck", "upstream_rev": "s3", "locked_rev": "s0" },
  { "input": "current", "upstream_rev": "c2", "locked_rev": "c0" },
  { "input": "manualpr", "upstream_rev": "m2", "locked_rev": "m0" },
  { "input": "gone", "upstream_rev": "g2", "locked_rev": "g0" }
]
EOF
bash "$WATCH" plan --heads "$T/heads-stale.json" --open-prs "$T/stale-prs.json" --pr-revs "$T/pr-revs.json" \
    --previous "$T/empty.json" --now "$PLAN_AT" >"$T/plan-stale.json"
eq "plan: a PR behind upstream is stale; a current one, or one whose revision is unknown, is not" \
    "stuck manualpr" "$(jq -r '[.moved[] | select(.pr_stale) | .input] | join(" ")' "$T/plan-stale.json")"
eq "plan: open PRs are still not classified" "" "$(jq -r '[.classify.linux[].input] | join(" ")' "$T/plan-stale.json")"
has "summary: lists stale PRs to refresh" "stale update PRs to refresh: stuck, manualpr" \
    "$(bash "$WATCH" summary --plan "$T/plan-stale.json")"

cat >"$T/policy-stale.json" <<'EOF'
{ "version": 1, "defaults": { "policy": "auto", "max_age_days": 7 },
  "inputs": { "manualpr": { "policy": "manual" } } }
EOF
mergeS() { # plan previous now
    bash "$WATCH" merge --plan "$1" --previous "$2" --policy "$T/policy-stale.json" \
        --linux "$T/empty.json" --darwin "$T/empty.json" --now "$3"
}
mergeS "$T/plan-stale.json" "$T/empty.json" "$NOW" >"$T/merged-stale-pr.json"
eq "merge: a stale PR under auto is refreshed; under manual it is not; current ones are left alone" \
    '["stuck"]' "$(jq -c '.dispatch' "$T/merged-stale-pr.json")"
eq "merge: the stale PR gets an entry for its revisions" "s3 s0" \
    "$(jq -r '.status.inputs.stuck | "\(.upstream_rev) \(.locked_rev)"' "$T/merged-stale-pr.json")"

# Once the refresh dispatch is recorded, the next hour does not repeat it...
jq .status "$T/merged-stale-pr.json" >"$T/prev-stale.json"
echo '[{"input":"stuck","rev":"s3"}]' >"$T/done-stale.json"
bash "$WATCH" mark-dispatched --status "$T/prev-stale.json" --inputs "$T/done-stale.json" --now "$NOW" >"$T/prev-stale2.json"
mergeS "$T/plan-stale.json" "$T/prev-stale2.json" "2026-11-11T13:00:00Z" >"$T/merged-stale-pr2.json"
eq "merge: a recorded refresh is not repeated" "[]" "$(jq -c '.dispatch' "$T/merged-stale-pr2.json")"
eq "merge: ...and keeps its record" "s3" "$(jq -r '.status.inputs.stuck.dispatched_rev' "$T/merged-stale-pr2.json")"
# ...unless the PR is still behind after the retry interval.
mergeS "$T/plan-stale.json" "$T/prev-stale2.json" "2026-11-11T18:00:00Z" >"$T/merged-stale-pr3.json"
eq "merge: still stale 6h later, refreshed again" '["stuck"]' "$(jq -c '.dispatch' "$T/merged-stale-pr3.json")"

# Once the refresh landed on the PR branch, the PR is current again.
echo '{"stuck":"s3","current":"c2","manualpr":"m1"}' >"$T/pr-revs-after.json"
bash "$WATCH" plan --heads "$T/heads-stale.json" --open-prs "$T/stale-prs.json" --pr-revs "$T/pr-revs-after.json" \
    --previous "$T/prev-stale2.json" --now "$PLAN_AT" >"$T/plan-after.json"
mergeS "$T/plan-after.json" "$T/prev-stale2.json" "2026-11-11T18:00:00Z" >"$T/merged-after.json"
eq "merge: a refreshed PR is no longer stale and not dispatched" "[]" "$(jq -c '.dispatch' "$T/merged-after.json")"

# ---------------------------------------------------------------------------
# classify (fake scripts/flake-input-impact.sh)
# ---------------------------------------------------------------------------

CLASSIFY="$ROOT/.github/scripts/flake-watch-classify.sh"
mkdir -p "$T/classify/scripts"
{
    printf '#!%s\n' "$(command -v bash)"
    cat <<'EOF'
# --os OS --json INPUT, or --os OS --base-fingerprint; "moved" reports a
# newer revision than planned.
input="${!#}"
case "$input" in
  --base-fingerprint) echo "B1" ;;
  cached) echo "evaluated a cached input" >&2; exit 1 ;;
  rebased) echo '{"input":"rebased","kind":"source","rev":"r4","changed":[]}' ;;
  ok) echo '{"input":"ok","kind":"source","rev":"r1","changed":[]}' ;;
  moved) echo '{"input":"moved","kind":"none","rev":"r9","changed":[]}' ;;
  broken) exit 1 ;;
esac
EOF
} >"$T/classify/scripts/flake-input-impact.sh"
chmod +x "$T/classify/scripts/flake-input-impact.sh"

set +e
OUT="$(cd "$T/classify" && INPUTS='[{"input":"ok","upstream_rev":"r1"},{"input":"moved","upstream_rev":"r2"},{"input":"broken","upstream_rev":"r3"},{"input":"cached","upstream_rev":"r5","cached_kind":"rebuild","cached_base":"B1"},{"input":"rebased","upstream_rev":"r4","cached_kind":"none","cached_base":"B0"}]' \
    bash "$CLASSIFY" linux 2>&1)"
RC=$?
set -e
eq "classify: a result for the planned revision is kept; a moved or failed one is not" \
    '{"ok":"source","rebased":"source"}' "$(jq -cS .kinds "$T/classify/impact-linux.json")"
eq "classify: the base fingerprint is recorded" "B1" "$(jq -r .base "$T/classify/impact-linux.json")"
has "classify: a kind cached against the same base is not evaluated again" "cached: rebuild (cached; base unchanged)" "$OUT"
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
policy_run '{"version":1,"defaults":{"policy":"auto","max_age_days":7},"inputs":{"onbranch":{"policy":"renovate"}}}'
eq "policy: renovate is a valid policy" 0 "$PRC"
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
