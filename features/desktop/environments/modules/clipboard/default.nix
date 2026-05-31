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
      wayland.windowManager.hyprland.extraConfig = ''
        --------------------
        ---- CLIPBOARD  ----
        --------------------

        hl.on("hyprland.start", function()
          hl.exec_cmd("wl-paste --type text --watch cliphist store")
          hl.exec_cmd("wl-paste --type image --watch cliphist store")
        end)

        hl.bind("SUPER + V", hl.dsp.exec_cmd("cliphist list | fuzzel --dmenu | cliphist decode | wl-copy"))
      '';
    });
  };
}
