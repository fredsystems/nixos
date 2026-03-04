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
      programs.lsd = {
        enable = true;
        enableZshIntegration = true;
      };

      catppuccin.lsd.enable = true;
    });
  };
}
