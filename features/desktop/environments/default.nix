{
  lib,
  config,
  pkgs,
  catppuccinWallpapers,
  user,
  extraUsers ? [ ],
  ...
}:
let
  cfg = config.desktop.environments;
  allUsers = [ user ] ++ extraUsers;
  inherit (config.desktop.environments.common) waitForWayland;
in
{
  options.desktop.environments = {
    enable = lib.mkEnableOption "desktop environments";
  };

  imports = [
    ./common.nix
    ./cosmic
    ./gnome
    ./hyprland
    ./modules
    ./niri
  ];

  config = lib.mkIf cfg.enable {
    systemd = {
      user.services = {
        # one-password-agent = {
        #   description = "1Password Background";
        #   unitConfig = {
        #     StartLimitIntervalSec = 0;
        #   };
        #   serviceConfig = {
        #     Type = "simple";
        #     ExecStartPre = waitForWayland;
        #     ExecStart = "${pkgs._1password-gui}/bin/1password --silent";
        #     Restart = "always";
        #     RestartSec = "2s";
        #   };
        # };

        udiskie-agent = {
          description = "udiskie Background";
          unitConfig = {
            StartLimitIntervalSec = 0;
          };
          serviceConfig = {
            Type = "simple";
            ExecStartPre = waitForWayland;
            ExecStart = "${pkgs.udiskie}/bin/udiskie --appindicator -t";
            Restart = "always";
            RestartSec = "2s";
          };
        };

        sway-audio-idle-inhibit = {
          description = "sway-audio-idle-inhibit Background";
          unitConfig = {
            StartLimitIntervalSec = 0;
          };
          serviceConfig = {
            Type = "simple";
            ExecStartPre = waitForWayland;
            ExecStart = "${pkgs.sway-audio-idle-inhibit}/bin/sway-audio-idle-inhibit";
            Restart = "always";
            RestartSec = "2s";
          };
        };
      };
    };

    desktop.environments = {
      common.enable = true;
      cosmic.enable = false;
      gnome.enable = false;
      hyprland.enable = true;
      niri.enable = true;
    };

    home-manager.users = lib.genAttrs allUsers (_: {
      # Browsable, source-attributed tree (orangci/, catppuccin/<cat>/, …).
      home.file."Pictures/Background".source = "${catppuccinWallpapers}/share/backgrounds";
      # Flat mirror: every image at the top level with a collision-safe name.
      # The wayle wallpaper cycler scans its cycling-directory
      # non-recursively, so it must point here rather than at the nested
      # Background tree (see flake/dev/packages.nix). Kept as a sibling so
      # the attributed tree above stays human-browsable.
      home.file."Pictures/Background-flat".source = "${catppuccinWallpapers}/share/backgrounds-flat";
    });
  };
}
