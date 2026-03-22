#!/usr/bin/env zsh
# shellcheck shell=bash disable=SC2207

bindkey '^[[F' end-of-line
bindkey '^[[H' beginning-of-line

clear-screen-and-scrollback() {
  printf '\x1Bc'
  zle clear-screen
}

zle -N clear-screen-and-scrollback
bindkey '^L' clear-screen-and-scrollback

_widgets=( $(zle -la) )

[[ -n "${_widgets[(r)down-line-or-beginning-search]}" ]] && bindkey '^[[B' down-line-or-beginning-search
[[ -n "${_widgets[(r)up-line-or-beginning-search]}"   ]] && bindkey '^[[A' up-line-or-beginning-search
unset _widgets
