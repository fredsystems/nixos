{
  user,
  extraUsers ? [ ],
  pkgs,
  lib,
  ...
}:
let
  allUsers = [ user ] ++ extraUsers;
in
{
  config = {
    home-manager.users = lib.genAttrs allUsers (_: {
      home.packages = with pkgs; [
        lazydocker
      ];

      programs.lazydocker = {
        enable = true;
        settings = {
          gui = {
            nerdFontsVersion = "3";
          };
        };
      };
    });
  };
}
