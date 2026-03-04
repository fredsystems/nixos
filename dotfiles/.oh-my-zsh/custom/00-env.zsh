#!/usr/bin/env zsh
# shellcheck shell=bash
# shellcheck disable=SC2034

# --- User paths and common dirs ---
GITHUB_DIR="${HOME}/GitHub"
export PRE_COMMIT_COLOR="never"

# OG cat function
if [[ "$HOME" == /home/* ]]; then
    ogcat() { /run/current-system/sw/bin/cat "$@"; }
else
    ogcat() { /etc/profiles/per-user/"$USER"/bin/cat "$@"; }
fi
