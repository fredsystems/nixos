{
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
