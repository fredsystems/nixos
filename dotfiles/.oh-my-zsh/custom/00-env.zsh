#!/usr/bin/env zsh
# shellcheck shell=bash
# shellcheck disable=SC1091
#
# Thin wrapper: the actual env lives in the shared, shell-agnostic file
# so bash and zsh share a single source of truth. See dotfiles/shell/.
source "${HOME}/.config/shell/00-env.sh"
