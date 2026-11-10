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
      programs.lazydocker = {
        enable = true;
        settings = {
          gui = {
            nerdFontsVersion = "3";
          };
        };
      };
    });
  };
}
