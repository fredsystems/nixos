{
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
    home-manager.users = lib.genAttrs allUsers (
      _:
      { config, ... }:
      let
        shellDir = "${config.home.homeDirectory}/.config/shell";
      in
      {
        programs.bash = {
          enable = true;
          enableCompletion = true;
          historySize = 10000;

          # Source the shell-agnostic config shared with zsh, plus the
          # bash-only readline keybindings. The shared files are installed
          # at ~/.config/shell by features/shell/default.nix. Order mirrors
          # zsh: env first, then keybindings, then aliases/functions, final.
          initExtra = ''
            source ${shellDir}/00-env.sh
            source ${shellDir}/20-bind.bash
            source ${shellDir}/10-aliases.sh
            source ${shellDir}/40-functions.sh
            source ${shellDir}/90-final.sh
          '';
        };

        # catppuccin.bash.enable = true;
      }
    );
  };
}
