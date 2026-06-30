#!/usr/bin/env bash
#
# check-upstream-fixes.sh
#
# Walks .github/tracked-upstream-fixes.json and decides, for each not-yet-done
# entry, whether the upstream fix we are waiting on has landed in a way that
# lets us revert the corresponding local workaround.
#
# Output: a JSON array (to stdout) of the entries that are now RESOLVED, each
# annotated with the evidence that resolved it. Diagnostics go to stderr.
#
# Requires: gh (authenticated), jq. Both are present on github-hosted runners.
#
# Exit codes:
#   0  ran successfully (regardless of whether anything resolved)
#   1  usage / environment / manifest error
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
MANIFEST="${1:-$REPO_ROOT/.github/tracked-upstream-fixes.json}"

if [[ ! -f "$MANIFEST" ]]; then
  echo "error: manifest not found: $MANIFEST" >&2
  exit 1
fi

for bin in gh jq; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "error: required tool not found: $bin" >&2
    exit 1
  fi
done

# Compare two semver-ish strings (strip leading v). Echoes "ge" if $1 >= $2.
semver_ge() {
  local a="${1#v}" b="${2#v}"
  local hi
  hi="$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1)"
  [[ "$hi" == "$a" ]] && echo "ge" || echo "lt"
}

# Latest *release* tag for a repo (falls back to newest tag if no releases).
latest_release_tag() {
  local repo="$1" tag
  tag="$(gh api "repos/$repo/releases/latest" --jq '.tag_name' 2>/dev/null || true)"
  if [[ -z "$tag" || "$tag" == "null" ]]; then
    tag="$(gh api "repos/$repo/tags" --jq '.[0].name' 2>/dev/null || true)"
  fi
  echo "$tag"
}

# Is `base` an ancestor of (or equal to) `head` in `repo`?
#   compare base...head -> status "ahead"/"identical" means head contains base.
commit_contained() {
  local repo="$1" base="$2" head="$3" status
  status="$(gh api "repos/$repo/compare/$base...$head" --jq '.status' 2>/dev/null || true)"
  case "$status" in
    ahead | identical) return 0 ;;
    *) return 1 ;;
  esac
}

# Version of a package as it resolves in THIS repo's pinned nixpkgs, via the
# flake. `host` selects which nixosConfiguration (hence which channel) to read
# from -- e.g. a stable host for the stable channel. Echoes the version or "".
pkg_version_in_pin() {
  local host="$1" pkg="$2"
  nix eval --raw --no-warn-dirty \
    ".#nixosConfigurations.${host}.pkgs.${pkg}.version" 2>/dev/null || true
}

# Is a PR merged in `repo`? Echoes the merge commit sha, or "" if not merged.
pr_merge_commit() {
  local repo="$1" num="$2"
  gh api "repos/$repo/pulls/$num" \
    --jq 'if .merged then .merge_commit_sha else "" end' 2>/dev/null || true
}

# The nixpkgs revision this repo currently pins, read from flake.lock.
# `node` selects which nixpkgs input (e.g. "nixpkgs" for unstable,
# "nixpkgs-stable" for stable). Echoes the rev or "".
pinned_nixpkgs_rev() {
  local node="$1"
  jq -r --arg n "$node" '.nodes[$n].locked.rev // empty' "$REPO_ROOT/flake.lock"
}

results='[]'

# Iterate not-done entries.
while IFS= read -r entry; do
  id="$(jq -r '.id' <<<"$entry")"
  repo="$(jq -r '.repo' <<<"$entry")"
  check="$(jq -r '.check' <<<"$entry")"

  echo "::group::checking $id ($check on $repo)" >&2

  resolved=false
  evidence=""

  case "$check" in
    release-contains-commit)
      fix_commit="$(jq -r '.fix_commit' <<<"$entry")"
      tag="$(latest_release_tag "$repo")"
      if [[ -z "$tag" ]]; then
        echo "  no release/tag found for $repo; skipping" >&2
      elif commit_contained "$repo" "$fix_commit" "$tag"; then
        resolved=true
        evidence="latest release \`$tag\` contains fix commit \`${fix_commit:0:12}\`"
      else
        echo "  latest release $tag does NOT yet contain $fix_commit" >&2
      fi
      ;;

    release-min-version)
      min_version="$(jq -r '.min_version' <<<"$entry")"
      tag="$(latest_release_tag "$repo")"
      if [[ -z "$tag" ]]; then
        echo "  no release/tag found for $repo; skipping" >&2
      elif [[ "$(semver_ge "$tag" "$min_version")" == "ge" ]]; then
        resolved=true
        evidence="latest release \`$tag\` >= required \`$min_version\`"
      else
        echo "  latest release $tag < $min_version" >&2
      fi
      ;;

    issue-closed)
      issue="$(jq -r '.issue' <<<"$entry")"
      state="$(gh api "repos/$repo/issues/$issue" --jq '.state' 2>/dev/null || true)"
      if [[ "$state" == "closed" ]]; then
        resolved=true
        evidence="issue #$issue is closed"
      else
        echo "  issue #$issue state=$state" >&2
      fi
      ;;

    pkgs-min-version)
      # Channel-aware: resolves only when the package version actually present
      # in our PINNED nixpkgs (read via the flake on `host`) is >= min_version.
      # This is the only honest signal for "the fix has landed in a channel we
      # install" -- a merged PR or a closed issue does NOT mean it's installable.
      #
      # `min_version` may legitimately be null when we know a fix is coming but
      # not yet which release carries it. In that case the entry is BLOCKED, not
      # resolved, and we additionally check the upstream PR/issue so the log
      # nudges us to fill in the version once it merges.
      min_version="$(jq -r '.min_version // empty' <<<"$entry")"
      pkg="$(jq -r '.package' <<<"$entry")"
      host="$(jq -r '.eval_host' <<<"$entry")"
      if [[ -z "$min_version" ]]; then
        echo "  BLOCKED: min_version not set yet for $pkg (waiting to learn which release carries the fix)" >&2
        # Surface upstream PR state if one is recorded, as a reminder.
        pr="$(jq -r '.upstream_pr // empty' <<<"$entry")"
        if [[ -n "$pr" ]]; then
          merge="$(pr_merge_commit "$repo" "$pr")"
          if [[ -n "$merge" ]]; then
            echo "  NOTE: upstream PR #$pr is MERGED (${merge:0:12}). Find the first nixpkgs nix release carrying it and set min_version." >&2
          else
            echo "  upstream PR #$pr not merged yet." >&2
          fi
        fi
      else
        cur="$(pkg_version_in_pin "$host" "$pkg")"
        if [[ -z "$cur" ]]; then
          echo "  could not evaluate $pkg version on host $host; skipping" >&2
        elif [[ "$(semver_ge "$cur" "$min_version")" == "ge" ]]; then
          resolved=true
          evidence="pinned \`$pkg\` is \`$cur\` (>= required \`$min_version\`) on \`$host\`"
        else
          echo "  pinned $pkg is $cur on $host (< $min_version)" >&2
        fi
      fi
      ;;

    nixpkgs-pin-contains-commit)
      # Channel-aware, for module-level nixpkgs changes that have no single
      # package version to gate on (e.g. a NixOS module fix). Resolved when the
      # `fix_commit` is contained in the nixpkgs revision THIS repo pins
      # (read from flake.lock). `pin_node` selects which nixpkgs input:
      # "nixpkgs" (unstable) or "nixpkgs-stable". The workaround can be reverted
      # only once every channel that needs it has the commit, so for a fix the
      # servers need, gate on the stable node.
      fix_commit="$(jq -r '.fix_commit' <<<"$entry")"
      pin_node="$(jq -r '.pin_node // "nixpkgs"' <<<"$entry")"
      pin_rev="$(pinned_nixpkgs_rev "$pin_node")"
      if [[ -z "$pin_rev" ]]; then
        echo "  could not read $pin_node rev from flake.lock; skipping" >&2
      elif commit_contained "$repo" "$fix_commit" "$pin_rev"; then
        resolved=true
        evidence="pinned \`$pin_node\` (\`${pin_rev:0:12}\`) contains fix commit \`${fix_commit:0:12}\`"
      else
        echo "  pinned $pin_node (${pin_rev:0:12}) does NOT yet contain ${fix_commit:0:12}" >&2
      fi
      ;;

    *)
      echo "  error: unknown check type '$check' for $id" >&2
      echo "::endgroup::" >&2
      exit 1
      ;;
  esac

  if [[ "$resolved" == true ]]; then
    echo "  RESOLVED: $evidence" >&2
    results="$(jq \
      --argjson entry "$entry" \
      --arg evidence "$evidence" \
      '. + [$entry + {evidence: $evidence}]' <<<"$results")"
  fi

  echo "::endgroup::" >&2
done < <(jq -c '.fixes[] | select(.done != true)' "$MANIFEST")

echo "$results"
