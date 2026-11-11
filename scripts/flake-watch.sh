#!/usr/bin/env bash
# scripts/flake-watch.sh
#
# The decision logic behind .github/workflows/flake-input-watch.yaml, kept
# out of the workflow YAML so it can be tested (scripts/tests/
# flake-watch-test.sh). See agent-docs/plans/PLAN_03_FLAKE_INPUT_TRACKING.md
# ("Observe and act are separate", "Impact is decided by evaluation").
#
# The workflow runs hourly:
#
#   candidates     branch-tracking GitHub root inputs, from flake.lock
#   resolve-heads  each candidate's upstream head, via `git ls-remote`
#                  (no API budget); inputs whose ref turns out to be a tag
#                  are dropped -- `nix flake update` cannot move a tag, and
#                  Renovate owns those
#   plan           which moved inputs need classifying on which OS
#   (classify)     scripts/flake-input-impact.sh, once per OS, on that OS's
#                  own runner (Darwin is never evaluated from Linux)
#   merge          the new status file, and the inputs to dispatch
#                  update-flakes.yaml for
#
# Every subcommand except resolve-heads is pure: JSON files in, JSON out.
#
# Status file (status/flake-inputs.json on the flake-watch branch, read by
# github-ci-exporter into github_flake_input_impact):
#
#   {
#     "version": 1,
#     "inputs": {
#       "<input>": {
#         "kinds": { "linux": "none|rebuild|source", "darwin": "..." },
#         "upstream_rev": "<upstream head the kinds were classified for>",
#         "locked_rev": "<our locked rev at the time>",
#         "classified_at": "<ISO 8601 UTC>"
#       }
#     }
#   }
#
# Only inputs that are behind upstream appear. An entry is reused, not
# re-evaluated, while both revisions are unchanged, and the file is written
# with sorted keys, so an hour in which nothing moved produces a
# byte-identical file and the workflow commits nothing.
#
# Usage:
#   flake-watch.sh candidates --lock FILE
#   flake-watch.sh resolve-heads --candidates FILE
#   flake-watch.sh plan --heads FILE --open-prs FILE --previous FILE
#   flake-watch.sh merge --plan FILE --previous FILE --policy FILE
#                        --linux FILE --darwin FILE --now ISO8601
#
# --open-prs is a JSON array of input names with an open `update-<input>`
# PR. --previous is the current status file, or {} when there is none yet.
# --linux / --darwin are {"<input>": "<kind>"} objects of this run's fresh
# classifications (either may be {}, e.g. when that OS's runner was down).
#
# Environment: FLAKE_WATCH_GIT overrides the git used by resolve-heads
# (tests substitute a fake).
set -euo pipefail

usage() {
  sed -n '/^# Usage:/,/^# --open-prs/p' "$0" | sed 's/^# \{0,1\}//' >&2
}

die() {
  echo "ERROR: $*" >&2
  exit 2
}

[[ $# -ge 1 ]] || {
  usage
  exit 2
}
CMD="$1"
shift

declare -A ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --lock | --candidates | --heads | --open-prs | --previous | --policy | --plan | --linux | --darwin | --now)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      ARGS["${1#--}"]="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

need() {
  local name
  for name in "$@"; do
    [[ -n "${ARGS[$name]:-}" ]] || die "$CMD requires --$name"
    if [[ "$name" != "now" && ! -r "${ARGS[$name]}" ]]; then
      die "--$name: no such file: ${ARGS[$name]}"
    fi
  done
}

# A root input is a candidate when it is locked from GitHub and follows a
# ref (a branch, a tag, or the default branch) rather than a pinned rev.
# Follows (array-valued root inputs) and every other lock type are not
# tracked here; the exporter reports them.
cmd_candidates() {
  need lock
  jq -c '
    .nodes as $n
    | [ .nodes.root.inputs
        | to_entries[]
        | select(.value | type == "string")
        | .key as $input
        | $n[.value] as $node
        | select($node.locked.type == "github" and $node.original.type == "github")
        | select(($node.original | has("rev")) | not)
        | {
            input: $input,
            owner: $node.locked.owner,
            repo: $node.locked.repo,
            ref: ($node.original.ref // null),
            locked_rev: $node.locked.rev
          }
      ]
    | sort_by(.input)
  ' "${ARGS[lock]}"
}

# Resolves one candidate row (JSON) to the row plus `upstream_rev`, or
# prints nothing when it is a tag or cannot be resolved this hour.
resolve_one() {
  local row="$1" git="${FLAKE_WATCH_GIT:-git}"
  local input owner repo ref url refs head
  input="$(jq -r .input <<<"$row")"
  owner="$(jq -r .owner <<<"$row")"
  repo="$(jq -r .repo <<<"$row")"
  ref="$(jq -r '.ref // empty' <<<"$row")"
  url="https://github.com/$owner/$repo"

  if [[ -z "$ref" ]]; then
    if ! refs="$("$git" ls-remote "$url" HEAD 2>&1)"; then
      echo "::warning title=flake-watch::$input: git ls-remote $url failed; skipping this hour: $refs" >&2
      return 0
    fi
    head="$(awk '$2 == "HEAD" { print $1; exit }' <<<"$refs")"
  else
    if ! refs="$("$git" ls-remote "$url" "refs/heads/$ref" "refs/tags/$ref" 2>&1)"; then
      echo "::warning title=flake-watch::$input: git ls-remote $url failed; skipping this hour: $refs" >&2
      return 0
    fi
    # A branch wins over a tag of the same name, as it does for Nix's own
    # resolution of `github:owner/repo/<ref>`.
    head="$(awk -v r="refs/heads/$ref" '$2 == r { print $1; exit }' <<<"$refs")"
    if [[ -z "$head" ]] && awk -v r="refs/tags/$ref" '$2 == r { f = 1 } END { exit !f }' <<<"$refs"; then
      echo "$input: pinned to tag $ref; not tracked here (Renovate owns tags)" >&2
      return 0
    fi
  fi

  if [[ -z "$head" ]]; then
    echo "::warning title=flake-watch::$input: $url has no ${ref:-HEAD}; skipping" >&2
    return 0
  fi
  jq -c --arg head "$head" '. + {upstream_rev: $head}' <<<"$row"
}

# Every lookup is its own short network round trip, so they run
# FLAKE_WATCH_JOBS (default 8) at a time; one by one, ~30 inputs take minutes.
cmd_resolve_heads() {
  need candidates
  local dir i=0 row
  dir="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand now: $dir is local
  trap "rm -rf '$dir'" EXIT
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    while [[ "$(jobs -rp | wc -l)" -ge "${FLAKE_WATCH_JOBS:-8}" ]]; do
      wait -n || true
    done
    resolve_one "$row" >"$dir/$(printf '%05d' "$i")" &
    i=$((i + 1))
  done < <(jq -c '.[]' "${ARGS[candidates]}")
  wait
  # Concatenated in candidate order (the zero-padded names sort that way),
  # so the output does not depend on which lookup finished first.
  cat /dev/null "$dir"/* 2>/dev/null | jq -cs .
}

cmd_plan() {
  need heads open-prs previous
  jq -cn \
    --slurpfile heads "${ARGS[heads]}" \
    --slurpfile prs "${ARGS[open-prs]}" \
    --slurpfile prev "${ARGS[previous]}" '
    ($prev[0].inputs // {}) as $p
    | [ $heads[0][]
        | select(.upstream_rev != .locked_rev)
        | {
            input,
            upstream_rev,
            locked_rev,
            pr_open: (.input as $i | $prs[0] | index($i) != null)
          }
      ] as $moved
    | def needs($os):
        [ $moved[]
          | select(.pr_open | not)
          | . as $m
          | ($p[$m.input] // null) as $e
          | select(
              $e == null
              or $e.upstream_rev != $m.upstream_rev
              or $e.locked_rev != $m.locked_rev
              or (($e.kinds // {}) | has($os) | not)
            )
          | .input
        ];
    {
      moved: $moved,
      classify: { linux: needs("linux"), darwin: needs("darwin") }
    }
  '
}

cmd_merge() {
  need plan previous policy linux darwin now
  jq -cn \
    --slurpfile plan "${ARGS[plan]}" \
    --slurpfile prev "${ARGS[previous]}" \
    --slurpfile policy "${ARGS[policy]}" \
    --slurpfile linux "${ARGS[linux]}" \
    --slurpfile darwin "${ARGS[darwin]}" \
    --arg now "${ARGS[now]}" '
    ($prev[0].inputs // {}) as $p
    | ($policy[0].defaults.policy // "auto") as $default_policy
    | [ $plan[0].moved[]
        | . as $m
        | ($p[$m.input] // null) as $e
        | ($e != null and $e.upstream_rev == $m.upstream_rev and $e.locked_rev == $m.locked_rev) as $same
        | ({ linux: $linux[0][$m.input], darwin: $darwin[0][$m.input] }
           | with_entries(select(.value != null))) as $fresh
        | if $m.pr_open then
            # An update PR is already open: nothing to classify or dispatch.
            # Keep what is known, for the dashboard.
            (if $e != null then { input: $m.input, entry: $e, dispatch: false } else empty end)
          else
            ((if $same then ($e.kinds // {}) else {} end) + $fresh) as $kinds
            | select($kinds != {})
            | {
                input: $m.input,
                entry: {
                  kinds: $kinds,
                  upstream_rev: $m.upstream_rev,
                  locked_rev: $m.locked_rev,
                  classified_at: (if $fresh != {} then $now else $e.classified_at end)
                },
                # Dispatch once per upstream revision: when this run first
                # finds a source change, not on every hour that follows.
                dispatch: (
                  (($policy[0].inputs[$m.input].policy // $default_policy) == "auto")
                  and ([$kinds[]] | index("source") != null)
                  and (($same and ([($e.kinds // {})[]] | index("source") != null)) | not)
                )
              }
          end
      ] as $rows
    | {
        status: { version: 1, inputs: ($rows | map({ key: .input, value: .entry }) | from_entries) },
        dispatch: [ $rows[] | select(.dispatch) | .input ]
      }
  '
}

case "$CMD" in
  candidates) cmd_candidates ;;
  resolve-heads) cmd_resolve_heads ;;
  plan) cmd_plan ;;
  merge) cmd_merge ;;
  -h | --help)
    usage
    exit 0
    ;;
  *) die "unknown subcommand: $CMD (candidates, resolve-heads, plan, merge)" ;;
esac
