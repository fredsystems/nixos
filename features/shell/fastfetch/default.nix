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

      programs.fastfetch = {
        enable = true;

        settings = builtins.fromJSON (builtins.readFile ./config.json);
      };
    });
  };
}
