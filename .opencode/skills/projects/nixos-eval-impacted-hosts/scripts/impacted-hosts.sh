#!/usr/bin/env bash
# scripts/impacted-hosts.sh
#
# Given a base ref (defaults to origin/main), print the NixOS host
# attribute names that need to be re-evaluated for the working tree's
# changes. Mirrors the `case` logic and flake.lock input-aware parsing
# in .github/workflows/ci-linux.yaml so an agent (or human) can run the
# same filter locally before pushing.
#
# Usage:
#   ./impacted-hosts.sh                 # diff against origin/main
#   ./impacted-hosts.sh HEAD~1          # diff against the previous commit
#   ./impacted-hosts.sh main --eval     # also run `nix eval` on each host's
#                                       # config.system.build.toplevel.drvPath
#
# Output: one host attribute name per line, or `GLOBAL` if every host is
# impacted. Empty output means no rebuild needed.

set -euo pipefail

BASE_REF="${1:-origin/main}"
shift || true
DO_EVAL=0
for arg in "$@"; do
  case "$arg" in
    --eval) DO_EVAL=1 ;;
  esac
done

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# Determine desktop hosts dynamically from ci-linux.yaml so this script
# never drifts from CI. (Falls back to the well-known list if parsing
# fails so the script is resilient to formatting changes.)
DESKTOP_NAMES=()
if [[ -f .github/workflows/ci-linux.yaml ]]; then
  while IFS= read -r line; do
    DESKTOP_NAMES+=("$line")
  done < <(
    grep -oE 'desktop_names=\("[^)]*"\)' .github/workflows/ci-linux.yaml \
      | tr ' ' '\n' \
      | grep -oE '"[A-Za-z0-9_-]+"' \
      | tr -d '"' || true
  )
fi
if [[ ${#DESKTOP_NAMES[@]} -eq 0 ]]; then
  DESKTOP_NAMES=("Daytona" "maranello")
fi

is_desktop() {
  local name="$1"
  for d in "${DESKTOP_NAMES[@]}"; do
    [[ "$name" == "$d" ]] && return 0
  done
  return 1
}

# Get the list of changed paths against the base ref.
CHANGED="$(git diff --name-only "$BASE_REF"...HEAD 2>/dev/null || git diff --name-only "$BASE_REF")"

# Walk the changed paths through the same `case` logic CI uses.
declare GLOBAL=0
declare DESKTOP_GLOBAL=0
declare SERVER_GLOBAL=0
declare -A PER_MACHINE=()
declare LOCK_CHANGED=0

while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  case "$path" in
    flake.nix|firmware.nix)
      GLOBAL=1
      ;;
    flake.lock)
      LOCK_CHANGED=1
      ;;
    modules/*|profiles/*|home-profiles/*|dotfiles/*|overlays/*)
      GLOBAL=1
      ;;
    features/desktop/*)
      DESKTOP_GLOBAL=1
      ;;
    features/*)
      GLOBAL=1
      ;;
    .github/renovate.json5)
      : # excluded
      ;;
    .github/*)
      GLOBAL=1
      ;;
    hosts/linux/*/*)
      # Extract the host directory name.
      host="${path#hosts/linux/}"
      host="${host%%/*}"
      PER_MACHINE[$host]=1
      ;;
    *) : ;;
  esac
done <<<"$CHANGED"

# Input-aware flake.lock parsing.
# Mirrors the input_category associative array in ci-linux.yaml.
declare -A INPUT_CATEGORY=(
  [nixpkgs]="desktop+fredhub"
  [home-manager]="desktop"
  [catppuccin]="desktop"
  [niri]="desktop"
  [freminal]="desktop"
  [frext]="desktop"
  [solaar]="desktop"
  [nix-flatpak]="desktop"
  [apple-fonts]="desktop"
  [walls-catppuccin]="desktop"
  [walls-zhichaoh]="desktop"
  [walls-cozypixels]="desktop"
  [nixvim]="global"
  [nixpkgs-stable]="server"
  [home-manager-stable]="server"
  [catppuccin-stable]="server"
  [sops-nix-stable]="server"
  [sops-nix]="desktop"
  [nix-yazi-plugins]="desktop"
  [nix-yazi-plugins-stable]="server"
  [nixos-needsreboot]="global"
  [darwin]="skip"
  [colmena]="skip"
  [flake-utils]="skip"
  [precommit-base]="skip"
)

if [[ $LOCK_CHANGED -eq 1 && $GLOBAL -eq 0 ]]; then
  # Compare each root input's locked.rev (or narHash) between base and HEAD.
  OLD_LOCK="$(git show "$BASE_REF":flake.lock 2>/dev/null || true)"
  NEW_LOCK="$(cat flake.lock)"
  if [[ -n "$OLD_LOCK" ]]; then
    # Use jq if available; otherwise fall back to "everything that's in the diff".
    if command -v jq >/dev/null 2>&1; then
      ROOT_INPUTS="$(echo "$NEW_LOCK" | jq -r '.nodes.root.inputs | keys[]')"
      for input in $ROOT_INPUTS; do
        OLD_REV="$(echo "$OLD_LOCK" | jq -r --arg i "$input" '.nodes[$i].locked.rev // .nodes[$i].locked.narHash // ""' 2>/dev/null)"
        NEW_REV="$(echo "$NEW_LOCK" | jq -r --arg i "$input" '.nodes[$i].locked.rev // .nodes[$i].locked.narHash // ""' 2>/dev/null)"
        [[ "$OLD_REV" == "$NEW_REV" ]] && continue

        category="${INPUT_CATEGORY[$input]:-global}"
        case "$category" in
          global) GLOBAL=1 ;;
          desktop) DESKTOP_GLOBAL=1 ;;
          server) SERVER_GLOBAL=1 ;;
          desktop+fredhub) DESKTOP_GLOBAL=1; PER_MACHINE[fredhub]=1 ;;
          skip) : ;;
        esac
        [[ $GLOBAL -eq 1 ]] && break
      done
    else
      # jq missing — safe over-build.
      GLOBAL=1
    fi
  else
    # No old lock retrievable — safe over-build.
    GLOBAL=1
  fi
fi

# Build the final host list.
# Fail loud if nix eval can't enumerate nixosConfigurations -- a broken
# flake silently producing an empty host list would defeat the whole
# point of this verification gate.
if ! ALL_HOSTS_JSON="$(nix eval .#nixosConfigurations --apply 'cfgs: builtins.attrNames cfgs' --json 2>&1)"; then
  printf 'ERROR: failed to enumerate nixosConfigurations:\n%s\n' "$ALL_HOSTS_JSON" >&2
  exit 1
fi
mapfile -t ALL_HOSTS < <(echo "$ALL_HOSTS_JSON" | tr -d '[]" ' | tr ',' '\n' | grep -v '^$')

if [[ $GLOBAL -eq 1 ]]; then
  printf '%s\n' "GLOBAL"
  HOSTS=("${ALL_HOSTS[@]}")
elif [[ $SERVER_GLOBAL -eq 1 && $DESKTOP_GLOBAL -eq 1 ]]; then
  printf '%s\n' "GLOBAL"
  HOSTS=("${ALL_HOSTS[@]}")
else
  HOSTS=()
  for h in "${ALL_HOSTS[@]}"; do
    if [[ $SERVER_GLOBAL -eq 1 ]] && ! is_desktop "$h"; then
      HOSTS+=("$h"); continue
    fi
    if [[ $DESKTOP_GLOBAL -eq 1 ]] && is_desktop "$h"; then
      HOSTS+=("$h"); continue
    fi
    if [[ -n "${PER_MACHINE[$h]+x}" ]]; then
      HOSTS+=("$h"); continue
    fi
    # Case-insensitive fallback for desktop_names mismatch (Daytona vs daytona).
    h_lower="$(echo "$h" | tr '[:upper:]' '[:lower:]')"
    if [[ -n "${PER_MACHINE[$h_lower]+x}" ]]; then
      HOSTS+=("$h")
    fi
  done
  printf '%s\n' "${HOSTS[@]}"
fi

# Optional: actually evaluate each host so we catch eval errors before push.
if [[ $DO_EVAL -eq 1 ]]; then
  echo "--- eval pass ---" >&2
  for h in "${HOSTS[@]}"; do
    echo "[eval] $h" >&2
    nix eval ".#nixosConfigurations.${h}.config.system.build.toplevel.drvPath" >/dev/null
  done
  echo "[eval] OK" >&2
fi
