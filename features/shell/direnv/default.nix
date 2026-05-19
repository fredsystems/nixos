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
      programs.direnv = {
        enable = true;
        enableBashIntegration = true;
        enableFishIntegration = true;
        enableZshIntegration = true;
        # Add any additional configuration for direnv here
      };
    });
  };
}
