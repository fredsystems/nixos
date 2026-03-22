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
      programs.btop = {
        enable = true;
      };
      catppuccin.btop.enable = true;
    });
  };
}
