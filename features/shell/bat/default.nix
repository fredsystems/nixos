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

      # Install bat
      home.packages = [ pkgs.bat ];

      programs.bat = {
        enable = true;

        config = {
          italic-text = "always";
          pager = "less --RAW-CONTROL-CHARS --quit-if-one-screen --mouse";
        };
      };

      # Theme
      catppuccin.bat.enable = true;
    });
  };
}
