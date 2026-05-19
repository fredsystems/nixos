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

      programs.fish = {
        enable = true;
      };

      catppuccin.fish.enable = true;
    });
  };
}
