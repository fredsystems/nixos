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
        fd
      ];

      programs.fd = {
        enable = true;
      };
    });
  };
}
