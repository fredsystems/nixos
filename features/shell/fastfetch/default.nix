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

      home.packages = [ pkgs.fastfetch ];

      programs.fastfetch = {
        enable = true;

        settings = builtins.fromJSON (builtins.readFile ./config.json);
      };
    });
  };
}
