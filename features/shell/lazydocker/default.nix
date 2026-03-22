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
