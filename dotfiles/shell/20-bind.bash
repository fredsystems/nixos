# shellcheck shell=bash
#
# Bash-only readline keybindings.
#
# This is the bash equivalent of the zsh `20-zle.zsh` ZLE bindings. zsh's
# `bindkey`/`zle` have no bash analogue; bash uses readline (`bind`). Only
# source this from bash — zsh keeps its own `20-zle.zsh`.

# Only meaningful in an interactive shell with readline available.
case $- in
  *i*) ;;
  *) return 0 ;;
esac

# `bind` is a builtin that is only usable when readline is active (a real
# interactive shell attached to a terminal). In non-TTY "interactive"
# contexts (some CI/test harnesses, here-doc driven shells) `bind` is not
# available and would spam "bind: command not found". Guard on it.
if ! type -t bind >/dev/null 2>&1; then
  return 0
fi

# Home / End — mirror the zsh `bindkey '^[[H' beginning-of-line` etc.
bind '"\e[H": beginning-of-line'
bind '"\e[F": end-of-line'

# Up / Down — prefix history search, matching zsh's
# up-line-or-beginning-search / down-line-or-beginning-search.
# readline's history-search-{backward,forward} search using the text
# from the start of the line up to the cursor, which is the closest
# native equivalent.
bind '"\e[A": history-search-backward'
bind '"\e[B": history-search-forward'

# Ctrl-L — clear screen AND scrollback (the zsh
# clear-screen-and-scrollback widget). `\ec` is the terminal hard-reset
# that wipes scrollback; then redraw the prompt.
clear-screen-and-scrollback() {
    printf '\ec'
}
bind -x '"\C-l": clear-screen-and-scrollback'
