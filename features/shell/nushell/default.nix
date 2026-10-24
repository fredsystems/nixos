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

      programs.nushell = {
        enable = true;
        loadSessionVariables = true;
      };

      catppuccin.nushell.enable = true;
    });
  };
}
