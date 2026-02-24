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
        pay-respects
      ];

      # programs.pay-respects = {
      #   enable = true;
      # };
    });
  };
}
