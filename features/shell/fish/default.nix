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

      programs.fish = {
        enable = true;
      };

      catppuccin.fish.enable = true;
    });
  };
}
