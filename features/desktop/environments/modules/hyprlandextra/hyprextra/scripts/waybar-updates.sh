#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Configuration
# -----------------------------
NIXOS_REPO="${NIXOS_REPO:-/home/fred/GitHub/nixos}"
MAIN_BRANCH="${MAIN_BRANCH:-main}"

# -----------------------------
# Helpers
# -----------------------------
json() {
    local text="$1"
    local class="$2"
    local tooltip="$3"
    printf '{"text":"%s","class":"%s","tooltip":"%s"}\n' "$text" "$class" "$tooltip"
}

# -----------------------------
# 1. Reboot required (highest priority)
# -----------------------------
if [[ -f /run/reboot-required ]]; then
    json "󰜉" "reboot" "Reboot required"
    exit 0
fi

# -----------------------------
# 2. Git state checks
# -----------------------------
if [[ ! -d "$NIXOS_REPO/.git" ]]; then
    json "󰏗" "unknown" "NixOS config is not a git repository"
    exit 0
fi

cd "$NIXOS_REPO"

# Current branch
current_branch="$(git symbolic-ref --short HEAD 2>/dev/null || true)"

# Non-main branch is considered dirty
if [[ -n "$current_branch" && "$current_branch" != "$MAIN_BRANCH" ]]; then
    json "󰏗" "updates" "On non-main branch: $current_branch"
    exit 0
fi

# Ensure we have an upstream
upstream="$(git for-each-ref --format='%(upstream:short)' "$(git symbolic-ref -q HEAD)" 2>/dev/null || true)"

if [[ -z "$upstream" ]]; then
    json "󰏗" "updates" "No upstream configured for $MAIN_BRANCH"
    exit 0
fi

# Fetch quietly (no output, no failure noise)
git fetch --quiet || true

# Count commits we are behind
behind="$(git rev-list --count HEAD.."$upstream" 2>/dev/null || echo 0)"

if ((behind > 0)); then
    json "󰏗" "updates" "Config behind upstream by $behind commit(s)"
    exit 0
fi

# -----------------------------
# 3. Clean state
# -----------------------------
json "󰏗" "clean" "System configuration up to date"
