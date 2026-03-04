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
    environment.systemPackages = [
      pkgs.btop
    ];

    home-manager.users = lib.genAttrs allUsers (_: {
      programs.btop = {
        enable = true;
      };
      catppuccin.btop.enable = true;
    });
  };
}
