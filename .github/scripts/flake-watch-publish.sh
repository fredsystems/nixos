#!/usr/bin/env bash
# .github/scripts/flake-watch-publish.sh FILE
#
# flake-input-watch.yaml's publish step: writes FILE to
# status/flake-inputs.json on the flake-watch branch of $REPO, committing
# only when the content changed. The branch is an orphan holding nothing
# else, created on first use; github-ci-exporter reads the file from it
# through the Contents API (agent-docs/plans/PLAN_03_FLAKE_INPUT_TRACKING.md,
# "Observe and act are separate").
#
# Needs GH_TOKEN (contents: write) and REPO (owner/name). Commits made with
# the workflow's GITHUB_TOKEN trigger no workflows, so this never starts CI.
set -euo pipefail

SRC="$(realpath "${1:?usage: flake-watch-publish.sh FILE}")"
: "${GH_TOKEN:?}" "${REPO:?}"
BRANCH="flake-watch"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

git init -q
# FLAKE_WATCH_REMOTE lets the tests publish to a local bare repository.
git remote add origin "${FLAKE_WATCH_REMOTE:-https://github.com/$REPO.git}"
# The token goes in a header for this one repository's config only, never
# into the remote URL (which git may echo in errors).
git config "http.https://github.com/.extraheader" \
  "AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\n')"

rc=0
git ls-remote --exit-code origin "refs/heads/$BRANCH" >/dev/null || rc=$?
case "$rc" in
  0)
    git fetch -q --depth 1 origin "$BRANCH"
    git checkout -q -B "$BRANCH" FETCH_HEAD
    ;;
  2)
    echo "$BRANCH does not exist yet; creating it as an orphan branch"
    git checkout -q --orphan "$BRANCH"
    cat >README.md <<'EOF'
# flake-watch

Written hourly by `.github/workflows/flake-input-watch.yaml` on `main`; do
not edit by hand. `status/flake-inputs.json` records the classified impact of
every flake input that is behind upstream, and is read by github-ci-exporter
into `github_flake_input_impact`. See `scripts/flake-watch.sh` on `main` for
the format.
EOF
    ;;
  *)
    echo "git ls-remote failed (exit $rc)" >&2
    exit 1
    ;;
esac

mkdir -p status
cp "$SRC" status/flake-inputs.json
git add -A
if git diff --cached --quiet; then
  echo "status/flake-inputs.json unchanged; nothing to commit"
  exit 0
fi

git -c user.name="github-actions[bot]" \
  -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
  commit -q -m "flake-watch: update status/flake-inputs.json"
git push -q origin "HEAD:refs/heads/$BRANCH"
echo "published status/flake-inputs.json to $BRANCH"
