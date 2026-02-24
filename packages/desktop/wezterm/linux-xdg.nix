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
      xdg.mimeApps.associations.added."x-terminal-emulator" = [ "wezterm.desktop" ];
    });
  };
}
