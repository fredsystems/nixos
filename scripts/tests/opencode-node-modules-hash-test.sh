#!/usr/bin/env bash
# Hermetic regression coverage for consumer-lock evaluation and toolchain keys.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/repo/scripts" "$work/repo/flake/lib" "$work/bin"
cp "$root/scripts/opencode-node-modules-hash.sh" "$work/repo/scripts/"
git -C "$work/repo" init --quiet
printf '{"nodes":{"root":{"inputs":{"opencode":"opencode"}},"opencode":{"locked":{"rev":"release"}}}}\n' > "$work/repo/flake.lock"
export MOCK_NIXPKGS_REV=toolchain-a MOCK_LOG="$work/calls" MOCK_READY="$work/ready"
cat > "$work/bin/nix" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_LOG"
case "$*" in
  *github:*) echo 'standalone upstream evaluation ignores consumer lock' >&2; exit 1 ;;
  'flake update --flake '*'/repo opencode/nixpkgs') touch "$MOCK_READY" ;;
  *'versionAtLeast'*) if [[ -f $MOCK_READY ]]; then echo true; else echo false; fi ;;
  *'nixpkgsRev = '*) printf '{"rev":"release","nixpkgsRev":"%s"}\n' "$MOCK_NIXPKGS_REV" ;;
  *'builtins.getFlake '*'.node_modules.outputHash') echo sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= ;;
  'build '*builtins.getFlake*'.node_modules')
    echo 'error: hash mismatch in fixed-output derivation' >&2
    echo '         got:    sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=' >&2
    exit 1 ;;
  *) echo "Unexpected nix call: $*" >&2; exit 1 ;;
esac
MOCK
chmod +x "$work/bin/nix"
export PATH="$work/bin:$PATH"
cd "$work/repo"
script=./scripts/opencode-node-modules-hash.sh
hash=$($script compute x86_64-linux)
[[ $hash == sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB= ]]
echo '{"nodeModules":{"aarch64-darwin":{"rev":"release","nixpkgsRev":"toolchain-a","hash":"old-darwin"}}}' > flake/lib/opencode-node-modules-hashes.json
$script record x86_64-linux "$hash"
jq -e '.nodeModules["x86_64-linux"].nixpkgsRev == "toolchain-a" and .nodeModules["aarch64-darwin"].hash == "old-darwin"' flake/lib/opencode-node-modules-hashes.json >/dev/null
export MOCK_NIXPKGS_REV=toolchain-b
$script record x86_64-linux "$hash"
jq -e '.nodeModules["x86_64-linux"].nixpkgsRev == "toolchain-b" and .nodeModules["aarch64-darwin"] == {rev:"release", nixpkgsRev:"toolchain-a", hash:"old-darwin"}' flake/lib/opencode-node-modules-hashes.json >/dev/null
$script relock
[[ -f $MOCK_READY ]]
updates_before=$(grep -c '^flake update ' "$MOCK_LOG")
$script relock
updates_after=$(grep -c '^flake update ' "$MOCK_LOG")
[[ $updates_after -eq $updates_before ]] # already compatible: no update
if $script compute invalid-system >/dev/null 2>&1; then
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
printf '#!/usr/bin/env bash\nexit 0\n' > "$script"
cat > "$work/bin/nix" <<'MOCK'
#!/usr/bin/env bash
case "$MOCK_DIAGNOSTIC" in
  clean) ;;
  warning) echo 'warning: fixture diagnostic' >&2 ;;
  error) echo 'error: fixture diagnostic' >&2; exit 1 ;;
esac
MOCK
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
