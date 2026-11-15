#!/usr/bin/env bash
#
# nix-build-no-warnings.sh -- `nix build`, failing on any evaluation warning.
#
# Nix prints `evaluation warning:` to stderr and still exits 0, so a warning
# never fails a job on its own. ci-linux.yaml and ci-darwin.yaml grep for it
# around each host build; this is the same rule for lint.yaml's checks, which
# evaluate configurations (exports-standalone, decoder-units-sync, ...) that
# no host build ever does.
#
# --no-eval-cache is always passed: a cached evaluation replays the result
# without re-running it, so its warnings are not printed and would slip past.
#
# Usage: scripts/nix-build-no-warnings.sh <nix build arguments...>
# Honours $NIX (default `nix`) so the tests can substitute a mock.

set -euo pipefail

NIX="${NIX:-nix}"

stderr_file="$(mktemp)"
trap 'rm -f "$stderr_file"' EXIT

# stdout passes straight through; stderr is shown live and kept for the grep.
set +e
{ "$NIX" build --no-eval-cache "$@" 2>&1 1>&3 3>&- | tee "$stderr_file" >&2; } 3>&1
status=${PIPESTATUS[0]}
set -e

if [[ $status -ne 0 ]]; then
  exit "$status"
fi

# grep exits 1 for "no match", which is the clean case. Anything above that
# (grep missing from PATH, unreadable log) must fail closed: an empty count
# would otherwise compare equal to 0 and pass every build.
grep_status=0
warnings=$(grep -c 'evaluation warning:' "$stderr_file") || grep_status=$?
if [[ $grep_status -gt 1 ]]; then
  echo "::error::could not scan the build log for evaluation warnings (grep exited ${grep_status})" >&2
  exit 1
fi
if [[ $warnings -ne 0 ]]; then
  echo "::error::${warnings} Nix evaluation warning(s) detected" >&2
  exit 1
fi
