{
  lib,
  config,
  pkgs,
  catppuccinWallpapers,
  user,
  extraUsers ? [ ],
  ...
}:
with lib;
let
  cfg = config.desktop.environments;
  allUsers = [ user ] ++ extraUsers;
in
{
  options.desktop.environments = {
    enable = mkOption {
      description = "Enable the desktop environments.";
      default = false;
    };
  };

  imports = [
    ./hyprland
    ./niri
    ./cosmic
    ./gnome
    ./modules
    ./common.nix
  ];

  config = mkIf cfg.enable {
    systemd = {
      user.services = {
        # bluetooth-agent = {
        #   description = "Bluetooth Agent";
        #   unitConfig = {
        #     StartLimitIntervalSec = 0;
        #   };
        #   serviceConfig = {
        #     Type = "simple";
        #     ExecStart = "${pkgs.blueman}/bin/blueman-applet";
        #     Restart = "always";
        #     RestartSec = "2s";
        #   };
        # };

        one-password-agent = {
          description = "1Password Background";
          unitConfig = {
            StartLimitIntervalSec = 0;
          };
          serviceConfig = {
            Type = "simple";
            ExecStart = "${pkgs._1password-gui}/bin/1password --silent";
            Restart = "always";
            RestartSec = "2s";
          };
        };

        udiskie-agent = {
          description = "udiskie Background";
          unitConfig = {
            StartLimitIntervalSec = 0;
          };
          serviceConfig = {
            Type = "simple";
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
