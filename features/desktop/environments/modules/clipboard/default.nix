{
  lib,
  pkgs,
  config,
  user,
  extraUsers ? [ ],
  ...
}:
let
  allUsers = [ user ] ++ extraUsers;
  cfg = config.desktop.environments.modules.clipboard;
in
{
  options.desktop.environments.modules.clipboard = {
    enable = lib.mkEnableOption "clipboard support for Hyprland";
  };

  config = lib.mkIf cfg.enable {
    # Clipboard history is Noctalia's (see ../noctalia); wl-clipboard stays
    # for scripts and editors.
    users.users = lib.genAttrs allUsers (_: {
      packages = [ pkgs.wl-clipboard ];
    });
  };
}
