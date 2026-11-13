#!/usr/bin/env bash
#
# nix-build-no-warnings-test.sh -- hermetic tests for
# scripts/nix-build-no-warnings.sh, the gate lint.yaml wraps its `nix build`
# steps in, using a mock nix.
#
# No network, no Nix daemon: runs as a flake check
# (`.#checks.<system>.nix-build-no-warnings`) and as a pre-commit hook.
#
# Usage: bash scripts/tests/nix-build-no-warnings-test.sh   (from the repo root)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$ROOT/scripts/nix-build-no-warnings.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The mock records its arguments, prints to stdout, and emits the stderr and
# exit status the case asks for.
cat > "$work/nix" <<'MOCK'
printf '%s\n' "$*" > "$MOCK_ARGS"
echo 'fixture stdout'
case "$MOCK_CASE" in
  clean) echo 'building fixture...' >&2 ;;
  warning) printf 'evaluation warning: one\nevaluation warning: two\n' >&2 ;;
  error) echo 'error: fixture failure' >&2; exit 3 ;;
esac
MOCK
export MOCK_ARGS="$work/args"
# The gate runs "$NIX" as a single word, so wrap the mock in an executable.
printf '#!%s\nexec bash %q "$@"\n' "$(command -v bash)" "$work/nix" > "$work/nix-wrapper"
chmod +x "$work/nix-wrapper"
export NIX="$work/nix-wrapper"

FAIL=0
bad() {
  FAIL=$((FAIL + 1))
  printf 'FAIL: %s\n' "$*" >&2
}

# A clean build passes, forwards its arguments after --no-eval-cache, and
# leaves stdout untouched.
export MOCK_CASE=clean
if out=$(bash "$GATE" --no-link .#checks.x86_64-linux.fixture 2>"$work/err"); then
  [[ $out == 'fixture stdout' ]] || bad "clean: stdout was '$out'"
  grep -q 'building fixture' "$work/err" || bad 'clean: stderr was not passed through'
else
  bad 'clean: build failed'
fi
[[ $(cat "$MOCK_ARGS") == 'build --no-eval-cache --no-link .#checks.x86_64-linux.fixture' ]] ||
  bad "clean: nix got '$(cat "$MOCK_ARGS")'"

# A successful build that printed warnings fails, and says how many.
export MOCK_CASE=warning
if bash "$GATE" .#x >/dev/null 2>"$work/err"; then
  bad 'warning: build with evaluation warnings passed'
fi
grep -q '::error::2 Nix evaluation warning(s) detected' "$work/err" ||
  bad 'warning: missing or wrong ::error:: annotation'

# A failing build keeps its own exit status.
export MOCK_CASE=error
status=0
bash "$GATE" .#x >/dev/null 2>&1 || status=$?
[[ $status -eq 3 ]] || bad "error: exit status $status, expected 3"

if [[ $FAIL -ne 0 ]]; then
  echo "$FAIL nix-build-no-warnings test(s) failed" >&2
  exit 1
fi
echo 'nix-build-no-warnings tests passed'
