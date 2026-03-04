{
  pkgs,
  user,
  extraUsers ? [ ],
  lib,
  ...
}:
let
  username = user;
  allUsers = [ username ] ++ extraUsers;
in
{
  config = {
    home-manager.users = lib.genAttrs allUsers (_: {
      home.packages = with pkgs; [
        lazygit
        gmp
      ];

      programs.lazygit = {
        enable = true;
        settings = {
          gui = {
            nerdFontsVersion = "3";
          };
        };
      };

      catppuccin.lazygit.enable = true;
    });
  };
}
