# shellcheck shell=bash
#
# Shared shell functions — sourced by BOTH zsh and bash.
# Keep this bash-portable. zsh-only constructs (setopt, zle, ${arr[(r)...]})
# are NOT allowed here; use the portable helpers below instead.

# Apply nounset + pipefail for the duration of the calling function.
#
# In zsh, callers historically used `setopt localoptions nounset pipefail`,
# which auto-restores the options when the function returns. bash has no
# function-local option scoping, so we emulate it: enable the options here,
# and have the caller restore them on the way out via `_shell_func_opts_off`.
# Under zsh, `setopt localoptions` would be cleaner, but this portable form
# behaves identically in both shells as long as callers pair the two calls.
_shell_func_opts_on() {
    set -o nounset
    set -o pipefail
}

_shell_func_opts_off() {
    set +o nounset
    set +o pipefail
}

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
    _shell_func_opts_on

    # Get current branch
    local current
    current="$(git symbolic-ref --short HEAD 2>/dev/null)" || {
        echo "Not on a branch (detached HEAD)" >&2
        _shell_func_opts_off
        return 1
    }

    if [ "$current" = "main" ]; then
        echo "Already on main — nothing to sync." >&2
        _shell_func_opts_off
        return 0
    fi

    # Make sure working tree is clean
    if ! git diff --quiet || ! git diff --cached --quiet; then
        echo "Working tree not clean — commit or stash first." >&2
        _shell_func_opts_off
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
        _shell_func_opts_off
        return 1
    }

    echo "✔ $current is now up to date with main"
    _shell_func_opts_off
}

pushcache() {
    # Do NOT enable errexit here — if any command fails before the function
    # returns, the shell would exit the *entire interactive session*.
    _shell_func_opts_on

    local jobs
    if command -v nproc >/dev/null 2>&1; then
        jobs="$(nproc)"
    else
        jobs="$(sysctl -n hw.ncpu)"
    fi

    # Detect Home Manager root (newer HM first)
    local HM_ROOT HM_PATH USER_PROFILE
    if [ -e "$HOME/.local/state/home-manager/gcroots/current-home" ]; then
        HM_ROOT="$HOME/.local/state/home-manager/gcroots/current-home"
    elif [ -e "$HOME/.local/state/nix/profiles/home-manager" ]; then
        HM_ROOT="$HOME/.local/state/nix/profiles/home-manager"
    else
        echo "Could not find Home Manager GC root" >&2
        _shell_func_opts_off
        return 1
    fi

    HM_PATH=$(readlink -f "$HM_ROOT")
    USER_PROFILE=$(readlink -f "/etc/profiles/per-user/${USER}")

    # System profile path differs between NixOS and nix-darwin
    local SYS_PROFILE
    if [ -e /run/current-system ]; then
        SYS_PROFILE=/run/current-system
    elif [ -e /nix/var/nix/profiles/system ]; then
        SYS_PROFILE=/nix/var/nix/profiles/system
    else
        echo "Could not find system profile" >&2
        _shell_func_opts_off
        return 1
    fi

    echo "Pushing home-manager cache to attic..."
    echo "  HM root: $HM_ROOT"
    attic push fred "$HM_PATH" \
        --ignore-upstream-cache-filter \
        -j "$jobs" || {
        echo "Failed to push home-manager cache" >&2
        _shell_func_opts_off
        return 1
    }

    echo
    echo "Pushing per-user cache to attic..."
    attic push fred "$USER_PROFILE" \
        --ignore-upstream-cache-filter \
        -j "$jobs" || {
        echo "Failed to push per-user cache" >&2
        _shell_func_opts_off
        return 1
    }

    echo
    echo "Pushing current-system cache to attic..."
    attic push fred "$SYS_PROFILE" \
        --ignore-upstream-cache-filter \
        -j "$jobs" || {
        echo "Failed to push system cache" >&2
        _shell_func_opts_off
        return 1
    }

    _shell_func_opts_off
}

updatenix() {
    local nixos_dir="${GITHUB_DIR}/nixos"
    local pushed=false
    local component versions line

    if [ "${HOME#/Users/}" != "$HOME" ]; then
        if [ "$(pwd)" != "$nixos_dir" ]; then
            pushd "$nixos_dir" >/dev/null || return
            pushed=true
        fi
        sudo darwin-rebuild switch --flake .#"$(hostname)"
        echo " Done with nix."
        echo " Upgrading brew"
        brew update
        brew upgrade
    else
        if [ "$(pwd)" != "$nixos_dir" ]; then
            pushd "$nixos_dir" >/dev/null || return 2
            pushed=true
        fi
        if ! sudo nixos-rebuild switch --flake .#"$(hostname)"; then
            [ "$pushed" = true ] && popd >/dev/null 2>&1 || true
            return 1
        fi
        sudo nixos-needsreboot

        if [ -f /run/reboot-required ]; then
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
        fi

        echo
        echo "╔═════════════════════════════════════════════════════════════════════════╗"
        echo "║ 🚨🚨🚨 Don't forget to run pc if this build was not built on CI! 🚨🚨🚨 ║"
        echo "╚═════════════════════════════════════════════════════════════════════════╝"
        echo

        pkill -RTMIN+8 waybar 2>/dev/null || true
    fi

    if [ "$pushed" = true ]; then
        popd >/dev/null || true
    fi
}

nvim_custom() {
    [ -z "${1:-}" ] && echo "Provide a file to edit" && return
    nvim "${GITHUB_DIR}/$1"
}

remove_dsstore() {
    pushd "${GITHUB_DIR}/${1:-}" >/dev/null || {
        echo "Repo not found"
        return
    }

    if [ -f "${HOME}/.config/scripts/remove_dsstore.sh" ]; then
        "${HOME}/.config/scripts/remove_dsstore.sh"
    elif [ -f "${GITHUB_DIR}/remove_dsstore.sh" ]; then
        "${GITHUB_DIR}/remove_dsstore.sh"
    else
        echo "No remove_dsstore script found"
    fi

    popd >/dev/null || return
}

gppush() {
    sign
    pushd "${GITHUB_DIR}/${1:-}" >/dev/null || {
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
    local rc=$?
    popd >/dev/null || true
    rm -rf "${HOME}/tmp"
    return $rc
}

gcverify() {
    [ -z "${2:-}" ] && echo "Provide commit message" && return
    sign
    pushd "${GITHUB_DIR}/${1:-}" >/dev/null || return
    git add . && gcam "$2"
    local rc=$?
    popd >/dev/null || true
    return $rc
}

gcnoverify() {
    [ -z "${2:-}" ] && echo "Provide commit message" && return
    sign
    pushd "${GITHUB_DIR}/${1:-}" >/dev/null || return
    git add . && git commit --all --no-verify -m "$2"
    local rc=$?
    popd >/dev/null || true
    return $rc
}

update_dev() {
    echo "Building dev shell..."
    system=$(nix eval --raw --impure --expr builtins.currentSystem)
    nix build --no-link --print-out-paths \
        ".#devShells.${system}.default" >devshell.paths

    echo "Building dev packages..."
    # Enumerate every packages.<system>.* attr; tolerate a flake that has
    # no `packages` output (or no entry for this system) at all.
    #
    # NOTE: `nix eval ".#packages.${system}"` cannot be used here. When the
    # flake has no `packages` output, the flake-installable resolver fails
    # *before* `--apply` runs, with a doubled-path error like
    #   does not provide attribute 'packages.<sys>.packages.<sys>'
    # The `packages or {}` default is never reached because resolution of
    # the selector itself is what fails. So we evaluate the whole flake's
    # outputs via `nix flake show --json` (no jq dependency) and pick out
    # packages.<system> with Nix-side defaults.
    local pkg_attrs show_json
    show_json="$(mktemp)"
    if nix flake show --json . >"$show_json" 2>/dev/null; then
        pkg_attrs=$(nix eval --raw --impure --expr "
            let j = builtins.fromJSON (builtins.readFile $show_json);
            in builtins.concatStringsSep \"\n\"
                 (builtins.attrNames ((j.packages or {}).\"${system}\" or {}))")
    else
        pkg_attrs=""
    fi
    rm -f "$show_json"
    while read -r attr; do
        [ -z "$attr" ] && continue
        echo "  building packages.${system}.${attr}"
        nix build --no-link --print-out-paths \
            ".#packages.${system}.${attr}" >>devshell.paths
    done <<<"$pkg_attrs"

    echo "Pushing built dev outputs to Attic..."
    # Push the realised store paths (and their closures) directly.
    xargs -r nix shell --inputs-from . nixpkgs#attic-client --command \
        attic push fred --ignore-upstream-cache-filter -j 2 <devshell.paths

    rm devshell.paths
}
