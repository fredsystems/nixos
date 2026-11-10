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
      programs.lsd = {
        enable = true;
        enableZshIntegration = true;
      };

      catppuccin.lsd.enable = true;
    });
  };
}
