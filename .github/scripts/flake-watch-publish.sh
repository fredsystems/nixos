#!/usr/bin/env bash
# .github/scripts/flake-watch-publish.sh PLAN POLICY LINUX DARWIN
#
# Publishes one job's view of the flake input watch: merges this job's
# classification results (LINUX / DARWIN, {"<input>": "<kind>"}, either may
# be {}) into the LATEST status/flake-inputs.json on the flake-watch branch,
# dispatches update-flakes.yaml for any source change that has not been
# dispatched yet, records the dispatches that succeeded, and commits only
# when the file changed. See scripts/flake-watch.sh for the rules and the
# file format.
#
# Called by the find job (no results: drops caught-up inputs and retries
# overdue dispatches) and by each OS's classify job (its own results), in
# whatever order they finish. Merging against the latest file each time is
# what makes that safe: a push rejected because another job published first
# is retried from a fresh fetch, and an input this job already dispatched is
# not dispatched again on retry.
#
# The branch is an orphan holding only a README and the status file, created
# on first use; github-ci-exporter reads the file through the Contents API.
# Commits made with the workflow's GITHUB_TOKEN start no workflows.
#
# Environment: GH_TOKEN (contents: write, actions: write) and REPO
# (owner/name). Tests set FLAKE_WATCH_REMOTE (a local bare repository) and
# FLAKE_WATCH_GH (a fake gh).
set -euo pipefail

[[ $# -eq 4 ]] || {
  echo "usage: flake-watch-publish.sh PLAN POLICY LINUX DARWIN" >&2
  exit 2
}
PLAN="$(realpath "$1")"
POLICY="$(realpath "$2")"
LINUX="$(realpath "$3")"
DARWIN="$(realpath "$4")"
: "${GH_TOKEN:?}" "${REPO:?}"
WATCH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/flake-watch.sh"
GH="${FLAKE_WATCH_GH:-gh}"
BRANCH="flake-watch"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
echo '[]' >"$WORK/dispatched.json"

# Fetches the branch into a fresh clone at $WORK/repo; creates it as an
# orphan when it does not exist yet.
checkout() {
  rm -rf "$WORK/repo"
  git init -q "$WORK/repo"
  cd "$WORK/repo"
  git remote add origin "${FLAKE_WATCH_REMOTE:-https://github.com/$REPO.git}"
  # The token goes in a header for this one clone only, never into the
  # remote URL (which git may echo in errors).
  git config "http.https://github.com/.extraheader" \
    "AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\n')"

  local rc=0
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
}

for attempt in 1 2 3 4 5; do
  checkout
  mkdir -p status
  if [[ -f status/flake-inputs.json ]]; then
    cp status/flake-inputs.json "$WORK/previous.json"
  else
    echo '{}' >"$WORK/previous.json"
  fi

  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  bash "$WATCH" merge --plan "$PLAN" --previous "$WORK/previous.json" --policy "$POLICY" \
    --linux "$LINUX" --darwin "$DARWIN" --now "$now" >"$WORK/merged.json"

  while IFS= read -r input; do
    [[ -n "$input" ]] || continue
    if jq -e --arg i "$input" 'index($i) != null' "$WORK/dispatched.json" >/dev/null; then
      continue
    fi
    echo "dispatching update-flakes for $input"
    if "$GH" workflow run update-flakes.yaml -R "$REPO" --ref main \
      -f target=auto -f single_input="$input"; then
      jq --arg i "$input" '. + [$i]' "$WORK/dispatched.json" >"$WORK/d.tmp"
      mv "$WORK/d.tmp" "$WORK/dispatched.json"
    else
      # Not recorded, so the next publish tries again.
      echo "::warning title=flake-watch::dispatching update-flakes for $input failed; retrying next hour" >&2
    fi
  done < <(jq -r '.dispatch[]' "$WORK/merged.json")

  jq '.status' "$WORK/merged.json" >"$WORK/status.json"
  bash "$WATCH" mark-dispatched --status "$WORK/status.json" --inputs "$WORK/dispatched.json" \
    --now "$now" | jq -S . >status/flake-inputs.json

  git add -A
  if git diff --cached --quiet; then
    echo "status/flake-inputs.json unchanged; nothing to commit"
    exit 0
  fi
  git -c user.name="github-actions[bot]" \
    -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
    commit -q -m "flake-watch: update status/flake-inputs.json"
  if git push -q origin "HEAD:refs/heads/$BRANCH"; then
    echo "published status/flake-inputs.json to $BRANCH"
    exit 0
  fi
  echo "push rejected (attempt $attempt); another job published first, merging again" >&2
  sleep $((attempt * 2))
done

echo "could not publish status/flake-inputs.json after 5 attempts" >&2
exit 1
