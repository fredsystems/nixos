#!/usr/bin/env bash
# Hermetic regression coverage for consumer-lock evaluation and toolchain keys.
# Runs from a hook and from a Nix build sandbox (flake/dev/checks.nix), which
# has no /usr/bin/env, so generated mocks get this bash's absolute path.
set -euo pipefail
bash_shebang="#!$(command -v bash)"
root="$(cd "$(dirname "$0")/../.." && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/repo/scripts" "$work/repo/flake/lib" "$work/bin"
cp "$root/scripts/opencode-node-modules-hash.sh" "$work/repo/scripts/"
chmod 0755 "$work/repo/scripts/opencode-node-modules-hash.sh" # read-only when copied from the store
git -C "$work/repo" init --quiet
printf '{"nodes":{"root":{"inputs":{"opencode":"opencode"}},"opencode":{"locked":{"rev":"release"}}}}\n' > "$work/repo/flake.lock"
export MOCK_NIXPKGS_REV=toolchain-a MOCK_LOG="$work/calls" MOCK_READY="$work/ready"
{
  echo "$bash_shebang"
  cat <<'MOCK'
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_LOG"
case "$*" in
  *github:*) echo 'standalone upstream evaluation ignores consumer lock' >&2; exit 1 ;;
  'flake update --flake '*'/repo opencode/nixpkgs') [[ -n ${MOCK_NEVER_READY:-} ]] || touch "$MOCK_READY" ;;
  *'opencode-bun.nix'*'aarch64-darwin'*)
    if [[ -f $MOCK_READY ]]; then echo '{"compatible":true}'; else echo '{"compatible":false}'; fi ;;
  *'nixpkgsRev = '*) printf '{"rev":"release","nixpkgsRev":"%s"}\n' "$MOCK_NIXPKGS_REV" ;;
  *'builtins.getFlake '*'.node_modules.outputHash') echo sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= ;;
  'build '*builtins.getFlake*'.node_modules.override'*'lib.fakeHash'*)
    echo 'error: hash mismatch in fixed-output derivation' >&2
    echo "         got:    ${MOCK_GOT:-sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=}" >&2
    exit 1 ;;
  # Any other node_modules build "succeeds", as a path already in the store
  # or a substituter would, without running the locked Bun.
  'build '*builtins.getFlake*'node_modules'*) ;;
  *) echo "Unexpected nix call: $*" >&2; exit 1 ;;
esac
MOCK
} > "$work/bin/nix"
chmod +x "$work/bin/nix"
export PATH="$work/bin:$PATH"
cd "$work/repo"
script=./scripts/opencode-node-modules-hash.sh
run() { bash "$script" "$@"; }
hash=$(run compute x86_64-linux)
[[ $hash == sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB= ]] # never upstream's cached hash
[[ $(MOCK_GOT=sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= run compute x86_64-linux) == sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= ]]
echo '{"nodeModules":{"aarch64-darwin":{"rev":"release","nixpkgsRev":"toolchain-a","hash":"old-darwin"}}}' > flake/lib/opencode-node-modules-hashes.json
run record x86_64-linux "$hash"
jq -e '.nodeModules["x86_64-linux"].nixpkgsRev == "toolchain-a" and .nodeModules["aarch64-darwin"].hash == "old-darwin"' flake/lib/opencode-node-modules-hashes.json >/dev/null
export MOCK_NIXPKGS_REV=toolchain-b
run record x86_64-linux "$hash"
jq -e '.nodeModules["x86_64-linux"].nixpkgsRev == "toolchain-b" and .nodeModules["aarch64-darwin"] == {rev:"release", nixpkgsRev:"toolchain-a", hash:"old-darwin"}' flake/lib/opencode-node-modules-hashes.json >/dev/null
if MOCK_NEVER_READY=1 run relock 2>/dev/null; then
  echo 'relock accepted a toolchain that is still incompatible after the bump' >&2
  exit 1
fi
[[ ! -f $MOCK_READY ]]
run relock
[[ -f $MOCK_READY ]]
updates_before=$(grep -c '^flake update ' "$MOCK_LOG")
run relock
updates_after=$(grep -c '^flake update ' "$MOCK_LOG")
[[ $updates_after -eq $updates_before ]] # already compatible: no update
if run compute invalid-system >/dev/null 2>&1; then
  echo 'unsupported system was accepted' >&2
  exit 1
fi

# Execute the actual workflow step: a warning must mark the run for failure,
# and a command error must stop it before any commit/push step is reached.
awk '
  /^      - name: Re-lock drifted inputs/ { step = 1; next }
  step && /^        run: \|/ { body = 1; next }
  body && /^          / { sub(/^          /, ""); print; next }
  body { exit }
' "$root/.github/workflows/renovate-relock.yaml" > "$work/relock-step.sh"
[[ -s $work/relock-step.sh ]]
# The step runs the script directly, so the stub needs a usable shebang.
printf '%s\nexit 0\n' "$bash_shebang" > "$script"
{
  echo "$bash_shebang"
  cat <<'MOCK'
case "$MOCK_DIAGNOSTIC" in
  clean) ;;
  warning) echo 'warning: fixture diagnostic' >&2 ;;
  error) echo 'error: fixture diagnostic' >&2; exit 1 ;;
esac
MOCK
} > "$work/bin/nix"
export GITHUB_OUTPUT="$work/outputs" MOCK_DIAGNOSTIC=clean
bash "$work/relock-step.sh"
[[ ! -s $GITHUB_OUTPUT ]]
export MOCK_DIAGNOSTIC=warning
bash "$work/relock-step.sh"
[[ $(cat "$GITHUB_OUTPUT") == diagnostics=true ]]
export MOCK_DIAGNOSTIC=error
if bash "$work/relock-step.sh"; then
  echo 'relock ignored a failing Nix command' >&2
  exit 1
fi
echo 'OpenCode hash/relock regression tests passed'
