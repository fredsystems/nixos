#!/usr/bin/env zsh
# shellcheck shell=bash
# shellcheck disable=SC1091
#
# Thin wrapper: shared final step lives in dotfiles/shell/90-final.sh so
# bash and zsh share one source of truth.
source "${HOME}/.config/shell/90-final.sh"
