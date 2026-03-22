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
      programs.fzf = {
        enable = true;
        enableZshIntegration = true;
      };

      catppuccin.fzf.enable = true;
    });
  };
}
