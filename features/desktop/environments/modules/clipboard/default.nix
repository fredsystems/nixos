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
    users.users = lib.genAttrs allUsers (_: {
      packages = with pkgs; [
        cliphist
        wl-clipboard
      ];
    });

    home-manager.users = lib.genAttrs allUsers (_: {
      wayland.windowManager.hyprland = {
        settings = {
          exec-once = [
            "wl-paste --type text --watch cliphist store"
            "wl-paste --type image --watch cliphist store"
          ];

          bind = [
            "SUPER, V, exec, cliphist list | fuzzel --dmenu | cliphist decode | wl-copy"
          ];
        };
      };
    });
  };
}
