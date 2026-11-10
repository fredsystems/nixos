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
      programs.btop = {
        enable = true;
      };
      catppuccin.btop.enable = true;
    });
  };
}
