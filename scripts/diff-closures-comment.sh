#!/usr/bin/env bash
#
# diff-closures-comment.sh
#
# Computes, for every host ci-linux.yaml's find-systems job flagged as
# impacted by a PR, what `nixosConfigurations.<host>.config.system.
# build.toplevel` actually changed between the PR base and HEAD, and
# renders a single markdown report body suitable for a PR comment.
#
# WHY THIS EXISTS
#
# A refactor asserted to be entirely behaviour-preserving can still be
# wrong in a way that only shows up on some hosts. The incident that
# motivated this script: all 8 servers came out byte-identical (correct),
# both desktops did not, and finding out *what* changed took a manual
# investigation across two commits -- comparing `system.path`,
# `environment.etc` names, `home.file` sources and text hashes by hand --
# and still did not fully resolve; the delta was somewhere inside the
# home-manager activation script.
#
# `nix store diff-closures` alone would not have caught it either: it
# groups by package name with the version stripped out, and a changed
# activation-script derivation keeps the same name and an empty
# ("epsilon") version on both sides, so a real content difference renders
# as literally nothing. Confirmed directly against the pair of maranello
# toplevels from that incident -- `nix store diff-closures <before>
# <after>` prints EMPTY for them despite the closures differing. This
# script therefore also computes a raw closure diff
# (`nix-store -qR`, sorted, `comm`'d) alongside `diff-closures`'s
# package/version view, specifically to surface that class of change.
#
# COST MODEL -- READ BEFORE CHANGING THE SUBSTITUTION LOGIC
#
# The AFTER side is cheap: build-servers/build-desktops already realised
# it earlier in the same workflow run and pushed it to the Attic cache at
# 192.168.31.14, so it substitutes.
#
# The BEFORE side (the PR base commit) is the one that could be
# expensive, and this script deliberately never pays that cost. Exactly
# two nix operations are used to get there:
#
#   1. `nix eval --raw` against a `git+file://...?rev=<base_sha>` flake
#      ref, to learn the base commit's toplevel outPath. This is a pure
#      evaluation -- no realisation is requested -- and costs only eval
#      time (observed ~12s warm against this repo's eval cache).
#   2. If, and only if, that outPath differs from HEAD's: attempt
#      `nix build --max-jobs 0 --no-link <path>`. `--max-jobs 0`
#      disables ALL local building, so this either substitutes from a
#      configured cache (Attic, cache.nixos.org, ...) or fails cleanly
#      with "local builds are disabled" / "no substituter can build it"
#      -- it can never silently fall back to a real build.
#
# Whether step 2 succeeds for the base commit depends entirely on
# whether that commit's closure is still cached. In practice this repo's
# merge queue builds every commit that reaches `main` before it merges,
# and Attic's default-retention-period is 30 days from last fetch (see
# modules/services/attic/attic_server.nix), so the common case -- a PR
# based on a recent `main` commit -- substitutes cleanly. It is NOT
# guaranteed: a long-lived PR, a base commit whose relevant host was
# never rebuilt by CI, or ordinary GC pressure can all make the base
# closure unavailable. When that happens this script reports the host as
# "unavailable" and moves on. It will never trigger a real closure
# realisation (the kind of build ci-linux.yaml's colmena-parity job
# comment measures at 578s/103s) just to populate a comment.
#
# OUTPUT CONTRACT
#
# All diagnostics go to stderr. On any successful run, stdout carries
# exactly one line:
#
#   STATUS=changed     body written to $OUT_FILE; something to report
#                       (a real diff, a new host, or a coverage gap)
#   STATUS=unchanged    body written to $OUT_FILE with a single "no
#                       changes" line -- the caller should update an
#                       existing PR comment if one exists, but must NOT
#                       create a new one (avoid noise on every PR)
#   STATUS=nothing      nothing written to $OUT_FILE; the caller should
#                       not post anything at all
#
# This script never fails the job it runs in: every error path degrades
# to STATUS=nothing (or drops just the one affected host into the
# "unavailable"/"eval error" bucket) rather than a non-zero exit, per
# ci-linux.yaml's "must never fail the PR" contract for this job.
#
# Usage:
#   BASE_SHA=<sha> HOSTS_JSON='["a","b"]' [RUN_URL=<url>] \
#     scripts/diff-closures-comment.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || {
  echo "error: cannot cd to repo root $REPO_ROOT" >&2
  echo "STATUS=nothing"
  exit 0
}

OUT_FILE="${OUT_FILE:-body.md}"
RUN_URL="${RUN_URL:-}"
SAMPLE_LIMIT=15

fail_nothing() {
  echo "error: $*" >&2
  # Per the OUTPUT CONTRACT above: STATUS=nothing means nothing written
  # to $OUT_FILE. Deliberately do not touch/truncate it here -- a caller
  # relying on the documented contract should never need to look at the
  # file when STATUS=nothing, but leaving a stale or unexpectedly-empty
  # file behind would be a silent contract violation if one ever did.
  echo "STATUS=nothing"
  exit 0
}

[ -n "${BASE_SHA:-}" ] || fail_nothing "BASE_SHA env var required"
[ -n "${HOSTS_JSON:-}" ] || fail_nothing "HOSTS_JSON env var required"

for tool in nix nix-store jq comm sort git sed head mktemp grep; do
  command -v "$tool" >/dev/null 2>&1 || fail_nothing "required tool not on PATH: $tool"
done

mapfile -t HOSTS < <(jq -r '.[]' <<<"$HOSTS_JSON" 2>/dev/null)
if [ "${#HOSTS[@]}" -eq 0 ]; then
  fail_nothing "HOSTS_JSON produced no hosts"
fi

echo "Diffing closures for: ${HOSTS[*]}" >&2
echo "Base: $BASE_SHA" >&2

# Must be reachable in this checkout (the workflow uses fetch-depth: 0,
# but a misconfigured checkout must degrade, not hard-fail).
if ! git cat-file -e "${BASE_SHA}^{commit}" 2>/dev/null; then
  fail_nothing "base commit $BASE_SHA not present locally (shallow checkout?)"
fi

declare -A STATUS
declare -A ERROR_SIDE
declare -A UNAVAILABLE_REASON
declare -A DIFF_OUTPUT
declare -A ADDED_SAMPLE
declare -A REMOVED_SAMPLE
declare -A ADDED_COUNT
declare -A REMOVED_COUNT
declare -A HEAD_PATH
declare -A BASE_PATH

# A host absent from the base commit's own nixosConfigurations (added by
# this PR) is not an error -- there is nothing to diff against. A host
# PRESENT at base whose toplevel eval nonetheless fails there IS a
# genuine eval error and must be reported as one, not silently folded
# into "new". Distinguishing the two requires knowing the base commit's
# attribute set up front, once, rather than inferring it from a single
# per-host eval failure (which cannot tell "absent" from "broken").
declare -A BASE_HOST_EXISTS
base_hosts_err="$(mktemp)"
if base_hosts_json="$(nix eval --json "git+file://${REPO_ROOT}?rev=${BASE_SHA}#nixosConfigurations" --apply builtins.attrNames 2>"$base_hosts_err")"; then
  while IFS= read -r bh; do
    [ -n "$bh" ] && BASE_HOST_EXISTS[$bh]=1
  done < <(jq -r '.[]' <<<"$base_hosts_json" 2>/dev/null)
  base_hosts_known=1
else
  # Could not even enumerate the base commit's hosts (e.g. the whole
  # base flake fails to evaluate). Do NOT default to "new" here -- that
  # would misreport a genuine base-wide breakage as a set of harmless
  # new hosts. Fall through to the per-host eval below, which will fail
  # the same way and be correctly reported as "error".
  echo "warning: could not enumerate base commit's nixosConfigurations:" >&2
  sed 's/^/  /' "$base_hosts_err" >&2
  base_hosts_known=0
fi
rm -f "$base_hosts_err"

for host in "${HOSTS[@]}"; do
  echo "== $host ==" >&2

  head_err="$(mktemp)"
  base_err="$(mktemp)"

  head_path="$(nix eval --raw ".#nixosConfigurations.${host}.config.system.build.toplevel.outPath" 2>"$head_err")"
  head_rc=$?

  if [ "$head_rc" -ne 0 ] || [ -z "$head_path" ]; then
    echo "  HEAD eval failed:" >&2
    sed 's/^/    /' "$head_err" >&2
    STATUS[$host]="error"
    ERROR_SIDE[$host]="head"
    rm -f "$head_err" "$base_err"
    continue
  fi

  rm -f "$head_err"

  if [ "$base_hosts_known" -eq 1 ] && [ -z "${BASE_HOST_EXISTS[$host]:-}" ]; then
    echo "  host not present in nixosConfigurations at base commit -- new host, nothing to diff" >&2
    STATUS[$host]="new"
    rm -f "$base_err"
    continue
  fi

  base_path="$(nix eval --raw "git+file://${REPO_ROOT}?rev=${BASE_SHA}#nixosConfigurations.${host}.config.system.build.toplevel.outPath" 2>"$base_err")"
  base_rc=$?

  if [ "$base_rc" -ne 0 ] || [ -z "$base_path" ]; then
    # The host IS present in the base commit's nixosConfigurations (or
    # we could not tell either way) yet its toplevel still fails to
    # evaluate there -- a genuine eval error at the base rev, not a new
    # host. Degrade like every other failure mode, but report it as
    # what it is.
    echo "  BASE eval failed (genuine eval error at base rev):" >&2
    sed 's/^/    /' "$base_err" >&2
    STATUS[$host]="error"
    ERROR_SIDE[$host]="base"
    rm -f "$base_err"
    continue
  fi
  rm -f "$base_err"

  HEAD_PATH[$host]="$head_path"
  BASE_PATH[$host]="$base_path"

  if [ "$head_path" = "$base_path" ]; then
    echo "  unchanged: $head_path" >&2
    STATUS[$host]="unchanged"
    continue
  fi

  echo "  before: $base_path" >&2
  echo "  after:  $head_path" >&2

  # Substitute-only. --max-jobs 0 disables all local building, so each
  # of these either pulls from a configured cache or fails cleanly --
  # see the cost-model note at the top of this file.
  if ! nix build --max-jobs 0 --no-link "$head_path" >/dev/null 2>"$head_err"; then
    echo "  AFTER closure not substitutable:" >&2
    sed 's/^/    /' "$head_err" >&2
    rm -f "$head_err"
    STATUS[$host]="unavailable"
    UNAVAILABLE_REASON[$host]="the after-closure is not in the cache yet (its build may still be running, or failed)"
    continue
  fi
  rm -f "$head_err"

  if ! nix build --max-jobs 0 --no-link "$base_path" >/dev/null 2>"$base_err"; then
    echo "  BEFORE closure not substitutable:" >&2
    sed 's/^/    /' "$base_err" >&2
    rm -f "$base_err"
    STATUS[$host]="unavailable"
    UNAVAILABLE_REASON[$host]="the base commit's closure is no longer cached (retention window, or it was never built) -- diffing it here would require a real rebuild, which this job intentionally will not do"
    continue
  fi
  rm -f "$base_err"

  # Both closures are locally present now (substituted, never built).
  #
  # `nix store diff-closures` emits ANSI colour codes for size deltas
  # unconditionally -- it ignores both a non-tty stdout and NO_COLOR in
  # this nix version -- so strip them before embedding the output in a
  # markdown code block, or GitHub renders the raw escape bytes.
  DIFF_OUTPUT[$host]="$(nix store diff-closures "$base_path" "$head_path" 2>/dev/null | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g')"

  # Raw closure diff: catches what diff-closures structurally cannot --
  # same package name, no version bump, size delta under its 8 KiB
  # threshold, but a genuinely different store path. This is the
  # home-manager-activation-script case this script exists for.
  before_req="$(nix-store -qR "$base_path" 2>/dev/null | sort -u)"
  after_req="$(nix-store -qR "$head_path" 2>/dev/null | sort -u)"

  removed="$(comm -23 <(printf '%s\n' "$before_req") <(printf '%s\n' "$after_req"))"
  added="$(comm -13 <(printf '%s\n' "$before_req") <(printf '%s\n' "$after_req"))"

  ADDED_COUNT[$host]="$(printf '%s\n' "$added" | grep -c . || true)"
  REMOVED_COUNT[$host]="$(printf '%s\n' "$removed" | grep -c . || true)"
  ADDED_SAMPLE[$host]="$(printf '%s\n' "$added" | head -n "$SAMPLE_LIMIT")"
  REMOVED_SAMPLE[$host]="$(printf '%s\n' "$removed" | head -n "$SAMPLE_LIMIT")"

  STATUS[$host]="changed"
done

# =============================================================================
# Decide whether there is anything worth posting at all.
#
# "unchanged" for every host is the common, boring, correct case -- do
# not manufacture a table for it. Anything else (a real diff, a new
# host, an eval error, or a coverage gap where we simply could not tell)
# is worth a line in the report so a reviewer knows what this check did
# and did not confirm.
# =============================================================================
show_report=0
for host in "${HOSTS[@]}"; do
  if [ "${STATUS[$host]}" != "unchanged" ]; then
    show_report=1
    break
  fi
done

if [ "$show_report" -eq 0 ]; then
  {
    echo "<!-- diff-closures-report -->"
    echo "### Closure diff"
    echo
    echo "No closure changes for any impacted host between \`${BASE_SHA:0:12}\` and this PR's HEAD: ${HOSTS[*]}."
  } >"$OUT_FILE"
  echo "STATUS=unchanged"
  exit 0
fi

{
  echo "<!-- diff-closures-report -->"
  echo "### Closure diff (base \`${BASE_SHA:0:12}\` -> HEAD)"
  echo
  if [ -n "$RUN_URL" ]; then
    echo "_Compares each impacted host's \`system.build.toplevel\` against the PR base. The before-closure is only ever substituted, never built -- see the header of \`scripts/diff-closures-comment.sh\` for the cost model. [Run]($RUN_URL)._"
  else
    echo "_Compares each impacted host's \`system.build.toplevel\` against the PR base. The before-closure is only ever substituted, never built -- see the header of \`scripts/diff-closures-comment.sh\` for the cost model._"
  fi
  echo
  echo "| Host | Status |"
  echo "| --- | --- |"
  for host in "${HOSTS[@]}"; do
    case "${STATUS[$host]}" in
      unchanged) label="unchanged" ;;
      changed) label="**changed**" ;;
      new) label="new host (no prior closure)" ;;
      unavailable) label="_diff unavailable_" ;;
      error) label="_eval error_" ;;
      *) label="${STATUS[$host]}" ;;
    esac
    echo "| \`${host}\` | ${label} |"
  done
  echo

  for host in "${HOSTS[@]}"; do
    case "${STATUS[$host]}" in
      changed)
        echo "#### \`${host}\`"
        echo
        echo "before: \`${BASE_PATH[$host]}\`"
        echo
        echo "after:  \`${HEAD_PATH[$host]}\`"
        echo

        if [ -n "${DIFF_OUTPUT[$host]}" ]; then
          echo "Package/version changes (\`nix store diff-closures\`):"
          echo
          echo '```'
          printf '%s\n' "${DIFF_OUTPUT[$host]}"
          echo '```'
          echo
        fi

        added_count="${ADDED_COUNT[$host]:-0}"
        removed_count="${REMOVED_COUNT[$host]:-0}"

        if [ -z "${DIFF_OUTPUT[$host]}" ] && { [ "$added_count" -gt 0 ] || [ "$removed_count" -gt 0 ]; }; then
          echo "> [!NOTE]"
          echo "> \`nix store diff-closures\` reported no package/version differences, but the two closures are not the same: ${added_count} store path(s) added, ${removed_count} removed. This is the case diff-closures cannot see (same package name, no version bump) -- for example, a changed home-manager activation script."
          echo
        fi

        if [ "$added_count" -gt 0 ]; then
          echo "<details><summary>${added_count} store path(s) added (showing up to ${SAMPLE_LIMIT})</summary>"
          echo
          echo '```'
          printf '%s\n' "${ADDED_SAMPLE[$host]}"
          echo '```'
          echo "</details>"
          echo
        fi

        if [ "$removed_count" -gt 0 ]; then
          echo "<details><summary>${removed_count} store path(s) removed (showing up to ${SAMPLE_LIMIT})</summary>"
          echo
          echo '```'
          printf '%s\n' "${REMOVED_SAMPLE[$host]}"
          echo '```'
          echo "</details>"
          echo
        fi
        ;;
      unavailable)
        echo "#### \`${host}\` -- diff unavailable"
        echo
        echo "${UNAVAILABLE_REASON[$host]}"
        echo
        ;;
      new)
        echo "#### \`${host}\` -- new host"
        echo
        echo "This host has no closure at the PR base to compare against."
        echo
        ;;
      error)
        echo "#### \`${host}\` -- eval error"
        echo
        case "${ERROR_SIDE[$host]:-}" in
          base) echo "Evaluating this host's toplevel failed at the PR base commit \`${BASE_SHA:0:12}\`; see the workflow run logs." ;;
          *) echo "Evaluating this host's toplevel failed at HEAD; see the workflow run logs." ;;
        esac
        echo
        ;;
    esac
  done
} >"$OUT_FILE"

echo "STATUS=changed"
