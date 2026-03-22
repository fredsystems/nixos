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
      programs.gh-dash = {
        enable = true;
      };

      catppuccin.gh-dash.enable = true;
    });
  };
}
