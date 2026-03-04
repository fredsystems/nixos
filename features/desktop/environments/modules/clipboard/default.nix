{
  lib,
  pkgs,
  config,
  user,
  extraUsers ? [ ],
  ...
}:
with lib;
let
  allUsers = [ user ] ++ extraUsers;
  cfg = config.desktop.environments.modules.clipboard;
in
{
  options.desktop.environments.modules.clipboard = {
    enable = mkOption {
      description = "Enable clipboard stuff for hyprland.";
      default = false;
    };
  };

  config = mkIf cfg.enable {
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
