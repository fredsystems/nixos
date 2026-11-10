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
      xdg.mimeApps = {
        associations.added."x-terminal-emulator" = [ "wezterm.desktop" ];
        defaultApplications."x-terminal-emulator" = [ "wezterm.desktop" ];
      };
    });
  };
}
