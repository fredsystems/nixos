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

        # Explicit position so the swap keybind (Super+Alt+Right, below) has
        # a deterministic default to flip against. This is niri's equivalent
        # of Hyprland's `auto-right`: the built-in panel sits at the origin
        # and the external monitor is placed to its right (x = 1920, the
        # logical width of this 1920x1200 @ 1.0 panel).
        position = {
          x = 0;
          y = 0;
        };

        mode = {
          width = 1920;
          height = 1200;
          refresh = 60.0;
        };
      };

      # Portable 4K monitor (15.6"): HiDPI scale. Placed to the right of
      # eDP-1 by default (external-right layout). x = 1920 is the built-in
      # panel's logical width, so the external sits flush against eDP-1's
      # right edge regardless of the external's own effective scale (niri may
      # snap the requested scale, which changes the external's logical
      # width). Super+Alt+Right toggles it to the left at runtime via
      # scripts/niri-swap-external.sh, which reads the live logical width so
      # the two outputs stay flush (no cursor-trapping gap) in either layout.
      "Genesys ATE Inc PM156R1-H" = {
        scale = 1.5;

        position = {
          x = 1920;
          y = 0;
        };

        mode = {
          width = 3840;
          height = 2160;
          refresh = 59.982;
        };
      };
    };

    binds = {
      # Toggle the portable external monitor between the right and left side
      # of the built-in panel. niri equivalent of Hyprland's
      # `SUPER+ALT+left/right` auto-left/auto-right swap; the script flips the
      # explicit logical x positions on each press.
      "Mod+Alt+Right".action = {
        spawn = [ "~/.config/hyprextra/scripts/niri-swap-external.sh" ];
      };

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

    -- Default for every monitor: auto-positioned, no scaling.
    hl.monitor({ output = "", mode = "highres", position = "auto-right", scale = 1 })

    -- Portable 4K monitor (15.6"): HiDPI scale, still auto-positioned.
    -- This specific desc: rule overrides the wildcard's scale above while
    -- leaving placement to Hyprland's auto-right.
    hl.monitor({ output = "desc:Genesys ATE Inc PM156R1-H", mode = "highres", position = "auto-right", scale = 1.5 })

    -- Swap external monitor position dynamically. Re-apply both the wildcard
    -- (for the position flip) and the 4K-specific rule (so its scale survives).
    hl.bind("SUPER + ALT + left",  hl.dsp.exec_cmd("hyprctl --batch 'keyword monitor ,highres,auto-left,1 ; keyword monitor desc:Genesys ATE Inc PM156R1-H,highres,auto-left,2'"))
    hl.bind("SUPER + ALT + right", hl.dsp.exec_cmd("hyprctl --batch 'keyword monitor ,highres,auto-right,1 ; keyword monitor desc:Genesys ATE Inc PM156R1-H,highres,auto-right,2'"))

    local scripts = os.getenv("HOME") .. "/.config/hyprextra/scripts"
    hl.bind("XF86MonBrightnessUp",   hl.dsp.exec_cmd(scripts .. "/backlight.sh 64764 --inc"), { locked = true, repeating = true })
    hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd(scripts .. "/backlight.sh 64764 --dec"), { locked = true, repeating = true })
  '';
}
