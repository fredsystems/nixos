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
        gh-dash
      ];

      programs.gh-dash = {
        enable = true;
      };

      catppuccin.gh-dash.enable = true;
    });
  };
}
