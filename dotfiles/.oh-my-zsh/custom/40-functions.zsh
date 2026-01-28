#!/usr/bin/env zsh
# shellcheck shell=bash

garbagecollect() {
    sudo nix-collect-garbage -d
    nix-collect-garbage -d
    updatenix
}

rebase() {
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
        echo "❌ Not inside a git repository" >&2
        return 1
    }

    if ! git diff --quiet || ! git diff --cached --quiet; then
        echo "❌ working tree not clean" >&2
        return 1
    fi

    if ! git symbolic-ref --quiet HEAD; then
        echo "❌ HEAD is detached" >&2
        return 1
    fi

    git fetch origin
    git rebase origin/main --exec 'git commit --amend --no-edit -S'
}

gitsig() {
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
        echo "❌ Not inside a git repository" >&2
        return 1
    }

    # get the number of commits to check from arg passed in, or if none, 1
    local num_commits=${1:-1}

    git log --show-signature -"${num_commits}"
}

git-sync-main() {
    set -euo pipefail

    # Get current branch
    local current
    current="$(git symbolic-ref --short HEAD 2>/dev/null)" || {
        echo "Not on a branch (detached HEAD)" >&2
        return 1
    }

    if [[ "$current" == "main" ]]; then
        echo "Already on main — nothing to sync." >&2
        return 0
    fi

    # Make sure working tree is clean
    if ! git diff --quiet || ! git diff --cached --quiet; then
        echo "Working tree not clean — commit or stash first." >&2
        return 1
    fi

    echo "Fetching origin..."
    git fetch origin

    echo "Merging origin/main → $current"
    git merge --no-ff origin/main -S || {
        echo
        echo "Merge conflict. Resolve, then:"
        echo "  git commit"
        echo "or abort with:"
        echo "  git merge --abort"
        return 1
    }

    echo "✔ $current is now up to date with main"
}

pushcache() {
    attic push fred /run/current-system --ignore-upstream-cache-filter
}

updatenix() {
    local nixos_dir="${GITHUB_DIR}/nixos"
    local pushed=false

    if [[ "$HOME" == /Users/* ]]; then
        if [[ "$(pwd)" != "$nixos_dir" ]]; then
            pushd "$nixos_dir" >/dev/null || return
            pushed=true
        fi
        sudo darwin-rebuild switch --flake .#"$(hostname)"
        echo " Done with nix."
        echo " Upgrading brew"
        brew update
        brew upgrade
    else
        if [[ "$(pwd)" != "$nixos_dir" ]]; then
            pushd "$nixos_dir" >/dev/null || return 2
            pushed=true
        fi
        sudo nixos-rebuild switch --flake .#"$(hostname)" || return 1
        sudo nixos-needsreboot

        if [[ -f /run/reboot-required ]]; then
            echo
            echo "╔══════════════════════════════════════════╗"
            echo "║        🔴 SYSTEM NEEDS A REBOOT          ║"
            echo "╚══════════════════════════════════════════╝"
            echo

            printf "  %-15s %-20s\n" "Component" "Upgrade"
            printf "  %-15s %-20s\n" "--------- " "--------"

            while IFS= read -r line; do
                component=$(echo "$line" | cut -d '(' -f 1)
                versions=$(echo "$line" | sed 's/.*(//;s/)//')
                printf "  \033[1;36m%-15s\033[0m %s\n" "$component" "$versions"
            done </run/reboot-required

            echo
        fi

        pkill -RTMIN+8 waybar 2>/dev/null || true
    fi

    [[ "$pushed" = true ]] && popd >/dev/null || return
}

updatedocker_ansible() {
    echo "Running Docker update playbook..."
    pushd "$ANSIBLE_DIR" >/dev/null || return
    ansible-playbook -i inventory.yaml plays/update_docker.yaml
    popd >/dev/null || return
}

updatesystems_ansible() {
    echo "Running system update playbook..."
    pushd "$ANSIBLE_DIR" >/dev/null || return
    ansible-playbook -i inventory.yaml plays/update_servers.yaml --ask-become-pass "$@"
    popd >/dev/null || return
}

rebootsystem_ansible() {
    [[ -z "$1" ]] && echo "Provide a system name" && return
    echo "Rebooting $1..."
    pushd "$ANSIBLE_DIR" >/dev/null || return
    ansible-playbook -i inventory.yaml -e "target_hosts=$1" plays/reboot_systems.yaml --ask-become-pass
    popd >/dev/null || return
}

nvim_custom() {
    [[ -z "$1" ]] && echo "Provide a file to edit" && return
    nvim "${GITHUB_DIR}/$1"
}

remove_dsstore() {
    pushd "${GITHUB_DIR}/$1" >/dev/null || {
        echo "Repo not found"
        return
    }

    if [[ -f "${HOME}/.config/scripts/remove_dsstore.sh" ]]; then
        "${HOME}/.config/scripts/remove_dsstore.sh"
    elif [[ -f "${GITHUB_DIR}/remove_dsstore.sh" ]]; then
        "${GITHUB_DIR}/remove_dsstore.sh"
    else
        echo "No remove_dsstore script found"
    fi

    popd >/dev/null || return
}

gppush() {
    sign
    pushd "${GITHUB_DIR}/$1" >/dev/null || {
        echo "Repo not found"
        return
    }
    git push
    popd >/dev/null || return
}

scar() {
    echo "Sync compose (remote→local)…"
    scr remote all
}

scal() {
    echo "Sync compose (local→remote)…"
    scr local all
}

sign() {
    mkdir -p "${HOME}/tmp"
    pushd "${HOME}/tmp" >/dev/null || return
    touch a.txt
    gpg --sign a.txt
    popd >/dev/null || return
    rm -rf "${HOME}/tmp"
}

gcverify() {
    [[ -z "$2" ]] && echo "Provide commit message" && return
    sign
    pushd "${GITHUB_DIR}/$1" >/dev/null || return
    git add .
    gcam "$2"
    popd >/dev/null || return
}

gcnoverify() {
    [[ -z "$2" ]] && echo "Provide commit message" && return
    sign
    pushd "${GITHUB_DIR}/$1" >/dev/null || return
    git add .
    git commit --all --no-verify -m "$2"
    popd >/dev/null || return
}
