{
  config,
  lib,
  ...
}:
let
  allUsers = config.shared.allUsers;
in
{
  config = {
    home-manager.users = lib.genAttrs allUsers (_: {
      programs.fzf = {
        enable = true;
        enableZshIntegration = true;
      };

      catppuccin.fzf.enable = true;
    });
  };
}
