{
  pkgs,
  user,
  extraUsers ? [ ],
  lib,
  ...
}:
let
  allUsers = [ user ] ++ extraUsers;
in
{
  config = {
    home-manager.users = lib.genAttrs allUsers (_: {
      programs.pay-respects = {
        enable = true;
        enableZshIntegration = false;
      };

      # Manually add only the command_not_found_handler for zsh.
      # The full zsh integration includes ZLE widget registration that
      # conflicts with starship's ZLE hooks and hangs on startup.
      programs.zsh.initContent = lib.mkOrder 1200 ''
        function __pr_base_zsh() {
          prefix=$(print -P "$PROMPT")
          _PR_MODE="$1" _PR_PREFIX="$prefix" _PR_LAST_COMMAND="$2" _PR_ALIAS="`alias`" _PR_SHELL="zsh" "${lib.getExe pkgs.pay-respects}"
        }
        command_not_found_handler() {
          eval $(__pr_base_zsh "cnf" "$*")
        }
      '';
    });
  };
}
