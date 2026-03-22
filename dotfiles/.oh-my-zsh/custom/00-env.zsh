#!/usr/bin/env zsh
# shellcheck shell=bash
# shellcheck disable=SC2034

# --- User paths and common dirs ---
GITHUB_DIR="${HOME}/GitHub"
export PRE_COMMIT_COLOR="never"

# Pre-set WEZTERM_HOSTNAME so the wezterm shell integration precmd hook
# doesn't fail under nounset (set -u). The wezterm.sh script checks this
# variable without the ${VAR-} guard, causing errors in non-WezTerm terminals
# when nounset is active.
if [[ -r /proc/sys/kernel/hostname ]]; then
  export WEZTERM_HOSTNAME
  WEZTERM_HOSTNAME="$(< /proc/sys/kernel/hostname)"
elif command -v hostname &>/dev/null; then
  export WEZTERM_HOSTNAME
  WEZTERM_HOSTNAME="$(hostname)"
else
  export WEZTERM_HOSTNAME="unknown"
fi

# OG cat function
if [[ "$HOME" == /home/* ]]; then
    ogcat() { /run/current-system/sw/bin/cat "$@"; }
else
    ogcat() { /etc/profiles/per-user/"$USER"/bin/cat "$@"; }
fi
