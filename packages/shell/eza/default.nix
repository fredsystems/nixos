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
      home.packages = with pkgs; [
        eza
      ];

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
