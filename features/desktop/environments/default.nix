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
    ./hyprland
    ./niri
    ./cosmic
    ./gnome
    ./modules
    ./common.nix
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
      hyprland.enable = true;
      niri.enable = true;
      cosmic.enable = false;
      gnome.enable = false;
    };

    home-manager.users = lib.genAttrs allUsers (_: {
      home.file."Pictures/Background".source = "${catppuccinWallpapers}/share/backgrounds";
    });
  };
}
