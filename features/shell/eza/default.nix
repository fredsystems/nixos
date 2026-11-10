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
      programs.eza = {
        enable = true;
        colors = "always";
        enableZshIntegration = true;
        git = true;
        icons = "always";
      };
    });
  };
}
