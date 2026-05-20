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

      programs.bash = {
        enable = true;
      };

      #catppuccin.bash.enable = true;
    });
  };
}
