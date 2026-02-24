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
  ];

  config = mkIf cfg.enable {
    systemd = {
      user.services = {
        polkit-gnome-authentication-agent-1 = {
          description = "polkit-gnome-authentication-agent-1";
          unitConfig = {
            StartLimitIntervalSec = 0;
          };
          serviceConfig = {
            Type = "simple";
            ExecStart = "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1";
            Restart = "always";
            RestartSec = "2s";
          };
        };

        bluetooth-agent = {
          description = "Bluetooth Agent";
          unitConfig = {
            StartLimitIntervalSec = 0;
          };
          serviceConfig = {
            Type = "simple";
            ExecStart = "${pkgs.blueman}/bin/blueman-applet";
            Restart = "always";
            RestartSec = "2s";
          };
        };

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

        user-sleep-hook = {
          description = "User Sleep Hook";
          unitConfig = {
            StartLimitIntervalSec = 0;
          };
          serviceConfig = {
            Type = "simple";
            ExecStart = "%h/.config/hyprextra/scripts/sleep.sh";
            Restart = "always";
            RestartSec = "2s";
          };
        };
      };
    };

    desktop.environments = {
      hyprland.enable = true;
      niri.enable = true;
      cosmic.enable = true;
      gnome.enable = true;
    };

    home-manager.users = lib.genAttrs allUsers (_: {
      home.file."Pictures/Background".source = "${catppuccinWallpapers}/share/backgrounds";
    });
  };
}
