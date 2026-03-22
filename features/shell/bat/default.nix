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
