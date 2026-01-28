#!/usr/bin/env zsh
# shellcheck shell=bash disable=SC2139

alias cd="z"

alias uz="${HOME}/.config/scripts/update-zsh-stuff.sh"
alias ugh="${HOME}/.config/scripts/update-all-git.sh ${GITHUB_DIR}"
alias ipc="${HOME}/.config/scripts/install-all-precommit.sh ${GITHUB_DIR}"
alias scr="$HOME/.local/bin/sync-compose"
alias ub="${HOME}/.config/scripts/update-brew.sh"

alias ls="lsd -la"
alias co="rustup update"
alias gc="gcverify"
alias gcn="gcnoverify"
alias gp="gppush"
alias gum="git-sync-main"

alias ng="nvim ${GITHUB_DIR}"
alias ngf="nvim ${GITHUB_DIR}/freminal"
alias ngs="nvim ${GITHUB_DIR}/sdre-hub"
alias ngc="nvim_custom"
alias na="nvim ${GITHUB_DIR}/docker-acarshub"
alias n="nvim"

alias rds="remove_dsstore"
alias cat="bat --color always"
alias c="zed ."

alias updatedocker="updatedocker_ansible"
alias updatesystems="updatesystems_ansible"
alias rebootsystem="rebootsystem_ansible"

alias nr="updatenix"
alias nd="garbagecollect"
alias pc="pushcache"

alias dtop="docker run -v /var/run/docker.sock:/var/run/docker.sock -it ghcr.io/amir20/dtop"

alias tools='nix develop ~/GitHub/fred-dev-tools --command zsh'
