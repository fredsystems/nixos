{
  pkgs,
  config,
  user,
  extraUsers ? [ ],
  lib,
  ...
}:
let
  allUsers = [ user ] ++ extraUsers;
  payRespectsCmd = lib.getExe pkgs.pay-respects;
in
{
  config = {
    home-manager.users = lib.genAttrs allUsers (_: {
      programs = {
        nix-index = {
          enable = true;
          enableBashIntegration = false;
          enableFishIntegration = false;
          enableNushellIntegration = false;
          enableZshIntegration = false;
        };

        pay-respects = {
          enable = true;
          enableZshIntegration = false;
        };

        # Inline the pay-respects zsh integration as static nix strings instead
        # of using eval "$(pay-respects zsh --alias)". Two issues with the eval
        # form: (1) zle -N inside an eval can trigger a ZLE redraw blocking on
        # TTY state; (2) something in the post-init hook chain (precmd/chpwd)
        # looks up a not-found command, invoking command_not_found_handler before
        # the shell is fully ready, causing pay-respects to block. Fix: inline
        # all functions statically and guard command_not_found_handler with a TTY
        # check ([[ -t 0 && -t 1 ]]) so it only runs in a real interactive shell.
        zsh.initContent = lib.mkOrder 1400 ''
          alias f="__pr_main suggest"

          function __pr_main() {
            eval $(__pr_base "$1" "$(fc -ln -1)")
          }

          function __pr_base() {
            prefix=$(print -P "$PROMPT")
            _PR_MODE="$1" _PR_PREFIX="$prefix" _PR_LAST_COMMAND="$2" _PR_ALIAS="$(alias)" _PR_SHELL="zsh" "${payRespectsCmd}"
          }

          function __pr_inline() {
            local input="$BUFFER"
            local output=$(__pr_base "inline" "$input")
            if [[ -n "$output" ]]; then
              BUFFER="$output"
              CURSOR=''${#BUFFER}
            fi
          }

          function command_not_found_handler() {
            [[ -t 0 && -t 1 ]] || return 127
            eval $(__pr_base "cnf" "$*")
          }

          if [[ $options[zle] = on ]]; then
            zle -N __pr_inline
            bindkey '^X^X' __pr_inline
          fi
        '';
      };
    });

    # Run nix-index weekly for each user as a system timer so the database
    # is kept fresh regardless of whether the user is logged in.
    # Linux only — systemd is not available on Darwin.
  }
  // lib.optionalAttrs config.nixpkgs.hostPlatform.isLinux {
    systemd.services = lib.listToAttrs (
      map (u: {
        name = "nix-index-${u}";
        value = {
          description = "Update nix-index database for ${u}";
          serviceConfig = {
            Type = "oneshot";
            User = u;
            ExecStart = "${lib.getExe' pkgs.nix-index "nix-index"}";
            Nice = 19;
            IOSchedulingClass = "idle";
          };
        };
      }) allUsers
    );

    systemd.timers = lib.listToAttrs (
      map (u: {
        name = "nix-index-${u}";
        value = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = "weekly";
            Persistent = true;
            RandomizedDelaySec = "4h";
          };
        };
      }) allUsers
    );
  };
}
