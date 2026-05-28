{
  config,
  ...
}:
{
  # ------------------------------
  # Host-specific Home Manager overrides for Daytona
  # ------------------------------

  imports = [
    ../../../home-profiles/desktop.nix
  ];

  systemd.user.services.mute-led-watcher = {
    Unit = {
      Description = "Sync keyboard mute LED with PipeWire mute state";
      After = [
        "pipewire.service"
        "wireplumber.service"
      ];
    };

    Service = {
      ExecStart = "${config.xdg.configHome}/hyprextra/scripts/watchsync.sh";
      Restart = "always";
      RestartSec = 1;
      StandardOutput = "journal";
      StandardError = "journal";
    };

    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  # Daytona-specific Home Manager settings
  programs.niri.settings = {
    outputs = {
      "eDP-1" = {
        scale = 1.0;

        mode = {
          width = 1920;
          height = 1200;
          refresh = 60.0;
        };
      };
    };

    binds = {
      "XF86MonBrightnessUp".action = {
        spawn = [
          "~/.config/hyprextra/scripts/backlight.sh"
          "64764"
          "--inc"
        ];
      };
      "XF86MonBrightnessDown".action = {
        spawn = [
          "~/.config/hyprextra/scripts/backlight.sh"
          "64764"
          "--dec"
        ];
      };
    };
  };

  wayland.windowManager.hyprland.extraConfig = ''
    --------------------
    ---- HOST: DAYTONA
    --------------------

    hl.monitor({ output = "", mode = "highres", position = "auto", scale = 1 })

    local scripts = os.getenv("HOME") .. "/.config/hyprextra/scripts"
    hl.bind("XF86MonBrightnessUp",   hl.dsp.exec_cmd(scripts .. "/backlight.sh 64764 --inc"), { locked = true, repeating = true })
    hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd(scripts .. "/backlight.sh 64764 --dec"), { locked = true, repeating = true })
  '';
}
