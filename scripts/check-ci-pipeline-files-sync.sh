#!/usr/bin/env bash
#
# check-ci-pipeline-files-sync.sh -- verify that every local script/action
# ci-linux.yaml and ci-darwin.yaml shell out to is registered in the
# matching FORCE_ALL_FILES array in scripts/impacted-hosts.sh.
#
# WHY THIS EXISTS
#
# scripts/impacted-hosts.sh decides whether a change forces a rebuild of
# every host, based on a hand-maintained FORCE_ALL_FILES list per OS (see
# that script's own header for the full rationale). Those files are, by
# construction, the ones a real derivation diff can never see a change to
# -- workflow YAML, and the scripts/actions the workflows shell out to
# directly. Missing an entry here is the dangerous direction: a change to
# an unregistered pipeline file could go completely unexercised by CI,
# with no rebuild and no error. That is a strictly worse failure mode than
# the inert-file allowlist in the same script being incomplete (worst
# case there: a missed optimisation, never a missed build) -- so unlike
# that allowlist, this one gets a mechanical check rather than a
# documented habit. See the nixos-ci-pipeline-file-sync skill.
#
# WHAT THIS CHECKS
#
# For each of ci-linux.yaml and ci-darwin.yaml: every `./scripts/*.sh`
# invocation and every local `uses: ./...` composite-action reference in
# the workflow file must appear, verbatim, in that OS's FORCE_ALL_FILES
# array in scripts/impacted-hosts.sh. A reference present in the workflow
# but absent from the array fails the check. An entry present in the
# array but no longer referenced by the workflow is reported as a
# non-fatal note (stale, safe to clean up, not a correctness risk).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

IMPACTED_SCRIPT="scripts/impacted-hosts.sh"

for f in "$IMPACTED_SCRIPT" .github/workflows/ci-linux.yaml .github/workflows/ci-darwin.yaml; do
  if [[ ! -f "$f" ]]; then
    echo "error: $f not found (run from the repository root)" >&2
    exit 1
  fi
done

# Extract the FORCE_ALL_FILES=( ... ) array that appears inside the
# `$os)` branch of the `case "$OS" in ... esac` block in
# scripts/impacted-hosts.sh.
extract_force_all() {
  local os="$1"
  awk -v os="$os" '
    $0 ~ "^  " os "\\)" { in_branch = 1 }
    in_branch && /FORCE_ALL_FILES=\(/ { in_array = 1; next }
    in_branch && in_array && /\)/ { in_array = 0; in_branch = 0; next }
    in_branch && in_array { print }
  ' "$IMPACTED_SCRIPT" | grep -oE '"[^"]+"' | tr -d '"'
}

# Extract every local script/action reference a workflow file shells out
# to: `./scripts/*.sh` invocations and `uses: ./...` composite actions.
# Both patterns tolerate an optional surrounding quote and arbitrary
# whitespace after `uses:`, since either is valid YAML (`uses:    "./foo"`)
# and a reference the regex fails to recognize is exactly the dangerous
# false-negative this checker exists to prevent.
extract_workflow_refs() {
  local workflow="$1"
  {
    grep -oE '"?\./scripts/[a-zA-Z0-9_.-]+\.sh"?' "$workflow" | tr -d '"' | sed 's#^\./##'
    grep -oE 'uses:[[:space:]]*"?'"'"'?\./[a-zA-Z0-9_./-]+'"'"'?"?' "$workflow" \
      | sed -E 's#^uses:[[:space:]]*["'"'"']?\./##; s#["'"'"']$##' \
      | sed -E 's#^#.github/#; s#$#/action.yaml#' \
      | sed -E 's#^\.github/\.github/#.github/#'
  } | sort -u
}

errors=()
notes=()

check_os() {
  local os="$1" workflow="$2"

  mapfile -t registered < <(extract_force_all "$os" | sort -u)
  mapfile -t referenced < <(extract_workflow_refs "$workflow")

  for ref in "${referenced[@]}"; do
    [[ -z "$ref" ]] && continue
    found=0
    for reg in "${registered[@]}"; do
      [[ "$ref" == "$reg" ]] && found=1 && break
    done
    if [[ $found -eq 0 ]]; then
      errors+=("${workflow} references '${ref}', which is not in the ${os} FORCE_ALL_FILES array in ${IMPACTED_SCRIPT}")
    fi
  done

  for reg in "${registered[@]}"; do
    [[ -z "$reg" ]] && continue
    # merge-queue-ci-skipper is shared/always-relevant; only flag scripts/
    # entries as potentially stale, since the action isn't picked up by
    # extract_workflow_refs's path-rewrite for every possible uses: form.
    case "$reg" in
      scripts/*.sh)
        found=0
        for ref in "${referenced[@]}"; do
          [[ "$ref" == "$reg" ]] && found=1 && break
        done
        if [[ $found -eq 0 ]]; then
          notes+=("${IMPACTED_SCRIPT}'s ${os} FORCE_ALL_FILES lists '${reg}', which ${workflow} no longer references (safe to remove, not a correctness risk)")
        fi
        ;;
    esac
  done
}

check_os "linux" ".github/workflows/ci-linux.yaml"
check_os "darwin" ".github/workflows/ci-darwin.yaml"

if [[ ${#notes[@]} -gt 0 ]]; then
  echo "notes (non-fatal):" >&2
  for n in "${notes[@]}"; do
    echo "  - ${n}" >&2
  done
fi

if [[ ${#errors[@]} -gt 0 ]]; then
  echo "CI pipeline files sync FAILED:" >&2
  echo "" >&2
  for e in "${errors[@]}"; do
    echo "  - ${e}" >&2
  done
  exit 1
fi

echo "CI pipeline files sync OK"
