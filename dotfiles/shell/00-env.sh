# shellcheck shell=bash
# shellcheck disable=SC2034
#
# Shared shell environment — sourced by BOTH zsh and bash.
# Keep this POSIX/bash-portable: no zsh-only or bash-only syntax.

# --- User paths and common dirs ---
GITHUB_DIR="${HOME}/GitHub"
export PRE_COMMIT_COLOR="never"

# Pre-set WEZTERM_HOSTNAME so the wezterm shell integration precmd hook
# doesn't fail under nounset (set -u). The wezterm.sh script checks this
# variable without the ${VAR-} guard, causing errors in non-WezTerm terminals
# when nounset is active.
if [ -r /proc/sys/kernel/hostname ]; then
  export WEZTERM_HOSTNAME
  WEZTERM_HOSTNAME="$(< /proc/sys/kernel/hostname)"
elif command -v hostname >/dev/null 2>&1; then
  export WEZTERM_HOSTNAME
  WEZTERM_HOSTNAME="$(hostname)"
else
  export WEZTERM_HOSTNAME="unknown"
fi

# OG cat function
if [ "${HOME#/home/}" != "$HOME" ]; then
    ogcat() { /run/current-system/sw/bin/cat "$@"; }
else
    ogcat() { /etc/profiles/per-user/"$USER"/bin/cat "$@"; }
fi
