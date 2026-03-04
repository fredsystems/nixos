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
        fzf
      ];

      programs.fzf = {
        enable = true;
        enableZshIntegration = true;
      };

      catppuccin.fzf.enable = true;
    });
  };
}
