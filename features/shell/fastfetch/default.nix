{
  config,
  lib,
  ...
}:

let
  allUsers = config.shared.allUsers;
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
