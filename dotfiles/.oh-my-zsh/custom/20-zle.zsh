#!/usr/bin/env zsh
# shellcheck shell=bash

bindkey '^[[F' end-of-line
bindkey '^[[H' beginning-of-line

clear-screen-and-scrollback() {
    printf '\x1Bc'
    zle clear-screen
}

zle -N clear-screen-and-scrollback
bindkey '^L' clear-screen-and-scrollback
