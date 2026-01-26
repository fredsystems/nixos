{
  lib,
  pkgs,
  config,
  user,
  ...
}:
with lib;
let
  username = user;
  cfg = config.desktop.environments.niri;
in
{
  options.desktop.environments.niri = {
    enable = mkOption {
      description = "Install Niri.";
      default = false;
    };
  };

  config = mkIf cfg.enable {
    users.users.${username} = {
      packages = with pkgs; [
        hyprpolkitagent

        grim
        hyprshot
        slurp
        swaybg
        swayidle
        swaylock
        wev
        playerctl
        libnotify
        brightnessctl
        sway-audio-idle-inhibit
        swaynotificationcenter
        blueman
        hyprpicker
        udiskie
        udisks
        libappindicator-gtk3
      ];
    };

    programs.niri = {
      enable = true;
    };
    programs.xwayland.enable = true;

    desktop.environments.modules.enable = true;

    services.displayManager.sddm = {
      enable = true;
      wayland.enable = true;

      settings = {
        Theme = {
          font = "SFProDisplay Nerd Font";
        };

        General = {
          RememberLastSession = true;
          RememberLastUser = true;
        };
      };
    };

    home-manager.users.${username} = {
      home.packages = with pkgs; [
        networkmanagerapplet
      ];

      programs.niri = {
        enable = true;
        settings = {
          hotkey-overlay.skip-at-startup = true;
          xwayland-satellite.path = lib.getExe pkgs.xwayland-satellite;

          input = {
            mod-key = "Super";
            focus-follows-mouse = {
              enable = true;
              max-scroll-amount = "25%";
            };
            keyboard = {
              numlock = true;
            };
          };

          spawn-at-startup = [
            {
              command = [
                "systemctl"
                "--user"
                "stop"
                "swaync"
              ];
            }
            # GTK theming
            {
              command = [
                "sh"
                "-c"
                "gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' && \
                 gsettings set org.gnome.desktop.interface gtk-theme 'Catppuccin-GTK-Mauve-Dark'"
              ];
            }

            # Wallpaper (same as swaybg in Hyprland)
            {
              command = [
                "~/.config/hyprextra/scripts/background.sh"
              ];
            }

            # Fred Bar
            {
              command = [
                "systemctl"
                "--user"
                "restart"
                "fredbar"
              ];
            }

            # Background helpers (systemd user units)
            {
              command = [
                "systemctl"
                "--user"
                "restart"
                "polkit-gnome-authentication-agent-1"
              ];
            }
            {
              command = [
                "systemctl"
                "--user"
                "restart"
                "sway-audio-idle-inhibit"
              ];
            }
            {
              command = [
                "systemctl"
                "--user"
                "restart"
                "user-sleep-hook"
              ];
            }
            {
              command = [
                "systemctl"
                "--user"
                "restart"
                "one-password-agent"
              ];
            }
            {
              command = [
                "systemctl"
                "--user"
                "restart"
                "network-manager-applet"
              ];
            }
            {
              command = [
                "systemctl"
                "--user"
                "restart"
                "bluetooth-agent"
              ];
            }
            {
              command = [
                "systemctl"
                "--user"
                "restart"
                "udiskie-agent"
              ];
            }
          ];

          layout = {
            # Hyprland gaps → Niri gaps
            gaps = 2;

            # Border (Hypr: border_size + colors)
            border = {
              enable = true;
              width = 2;

              active.color = "#bd93f9"; # closest match to your gradient
              inactive.color = "#44475aaa"; # matches rgba(44475aaa)
            };

            # Niri's focus ring = Hyprland's active border highlight
            focus-ring = {
              enable = true;
              width = 2;

              active.color = "#e0e0e0ff";
              inactive.color = "#00000000";
            };

            # Niri doesn't do rounded corners or shadows → ignore Hypr "decoration"
          };

          overview.backdrop-color = "#0f0f0f";

          switch-events = {
            "lid-close" = {
              action = {
                spawn = [
                  "~/.config/hyprextra/scripts/pauseandsleep.sh"
                ];
              };
            };
          };

          window-rules = [
            {
              open-maximized = true;
            }
          ];

          binds = {
            # --- App Launchers ---
            "Mod+F".action = {
              spawn = [ "firefox" ];
            };

            "Mod+E".action = {
              spawn = [
                "thunderbird"
              ];
            };

            "Mod+T".action = {
              spawn = [ "wezterm" ];
            };

            "Mod+Shift+T".action = {
              spawn = [
                "wezterm"
                "start"
                "--"
                "bash"
              ];
            };

            "Mod+A".action = {
              spawn = [ "nautilus" ];
            };

            "Mod+S".action = {
              spawn = [ "~/.config/hyprextra/scripts/idleinhibit.sh" ];
            };

            "Alt+Space".action = {
              spawn = [
                "vicinae"
                "toggle"
              ];
            };

            # --- Kill window / exit ---
            "Mod+C".action = {
              close-window = { };
            };

            "Mod+M".action = {
              quit = { };
            };

            # Lock / sleep
            "Mod+L".action = {
              spawn = [
                "/home/${username}/.config/hyprextra/scripts/pauseandsleep.sh"
              ];
            };

            # --- Move windows (Hypr: movewindow) ---
            "Mod+Left".action = {
              move-column-left = { };
            };
            "Mod+Right".action = {
              move-column-right = { };
            };
            "Mod+Up".action = {
              move-window-to-workspace-up = { };
            };
            "Mod+Down".action = {
              move-window-to-workspace-down = { };
            };

            "Mod+4".action = {
              set-column-width = "40%";
            };
            "Mod+5".action = {
              set-column-width = "50%";
            };
            "Mod+6".action = {
              set-column-width = "60%";
            };
            "Mod+7".action = {
              set-column-width = "70%";
            };
            "Mod+8".action = {
              set-column-width = "80%";
            };
            "Mod+9".action = {
              set-column-width = "90%";
            };
            "Mod+0".action = {
              set-column-width = "100%";
            };

            "Mod+MouseForward".action = {
              focus-column-left = { };
            };

            "Mod+MouseBack".action = {
              focus-column-right = { };
            };

            # --- Move focus (Hypr: movefocus) ---
            "Mod+Shift+Left".action = {
              focus-column-left = { };
            };
            "Mod+Shift+Right".action = {
              focus-column-right = { };
            };
            "Mod+Shift+Up".action = {
              focus-window-or-workspace-up = { };
            };
            "Mod+Shift+Down".action = {
              focus-window-or-workspace-down = { };
            };

            # --- Screenshots ---
            "Print".action = {
              spawn = [
                "sh"
                "grim"
              ];
            };
            "Mod+Print".action = {
              spawn = [
                "sh"
                "-c"
                "grim -g \"$(slurp)\""
              ];
            };

            # --- Workspace switching ---
            # "Mod+1".action = {
            #   focus-workspace = 1;
            # };
            # "Mod+2".action = {
            #   focus-workspace = 2;
            # };
            # "Mod+3".action = {
            #   focus-workspace = 3;
            # };
            # "Mod+4".action = {
            #   focus-workspace = 4;
            # };
            # "Mod+5".action = {
            #   focus-workspace = 5;
            # };
            # "Mod+6".action = {
            #   focus-workspace = 6;
            # };
            # "Mod+7".action = {
            #   focus-workspace = 7;
            # };
            # "Mod+8".action = {
            #   focus-workspace = 8;
            # };
            # "Mod+9".action = {
            #   focus-workspace = 9;
            # };
            # "Mod+0".action = {
            #   focus-workspace = 10;
            # };

            # --- Move active window to workspace ---
            # "Mod+Shift+1".action = {
            #   move-column-to-workspace = 1;
            # };
            # "Mod+Shift+2".action = {
            #   move-column-to-workspace = 2;
            # };
            # "Mod+Shift+3".action = {
            #   move-column-to-workspace = 3;
            # };
            # "Mod+Shift+4".action = {
            #   move-column-to-workspace = 4;
            # };
            # "Mod+Shift+5".action = {
            #   move-column-to-workspace = 5;
            # };
            # "Mod+Shift+6".action = {
            #   move-column-to-workspace = 6;
            # };
            # "Mod+Shift+7".action = {
            #   move-column-to-workspace = 7;
            # };
            # "Mod+Shift+8".action = {
            #   move-column-to-workspace = 8;
            # };
            # "Mod+Shift+9".action = {
            #   move-column-to-workspace = 9;
            # };
            # "Mod+Shift+0".action = {
            #   move-column-to-workspace = 10;
            # };

            # --- Workspace scroll (mouse wheel) ---
            "Mod+WheelScrollDown".action = {
              focus-workspace-down = { };
            };
            "Mod+WheelScrollUp".action = {
              focus-workspace-up = { };
            };

            "XF86AudioRaiseVolume".action = {
              spawn = [
                "~/.config/hyprextra/scripts/volume.sh"
                "--inc"
              ];
            };

            "XF86AudioLowerVolume".action = {
              spawn = [
                "~/.config/hyprextra/scripts/volume.sh"
                "--dec"
              ];
            };

            "XF86AudioMute".action = {
              spawn = [
                "~/.config/hyprextra/scripts/volume.sh"
                "--toggle"
              ];
            };

            "XF86AudioMicMute".action = {
              spawn = [
                "~/.config/hyprextra/scripts/volume.sh"
                "--toggle-mic"
              ];
            };

            "XF86AudioPlay".action = {
              spawn = [
                "playerctl"
                "play-pause"
              ];
            };

            "XF86AudioPause".action = {
              spawn = [
                "playerctl"
                "play-pause"
              ];
            };

            "XF86AudioNext".action = {
              spawn = [
                "playerctl"
                "next"
              ];
            };

            "XF86AudioPrev".action = {
              spawn = [
                "playerctl"
                "previous"
              ];
            };

            # "XKB_KEY_XF86KbdBrightnessUp".action = {
            #   spawn = [
            #     "~/.config/hyprextra/scripts/kbbacklight.sh"
            #     "--inc"
            #   ];
            # };

            # "XKB_KEY_XF86KbdBrightnessDown".action = {
            #   spawn = [
            #     "~/.config/hyprextra/scripts/kbbacklight.sh"
            #     "--dec"
            #   ];
            # };

            "XF86SelectiveScreenshot".action = {
              spawn = [
                "grim"
                "-g"
                "$(slurp)"
              ];
            };

            "XF86Display".action = {
              spawn = [
                "~/.config/hyprextra/scripts/pauseandsleep.sh"
              ];
            };

            "XF86Favorites".action = {
              spawn = [ "fuzzel" ];
            };

            "Mod+XF86MonBrightnessUp".action = {
              spawn = [
                "~/.config/hyprextra/scripts/kbbacklight.sh"
                "--inc"
              ];
            };

            "Mod+XF86MonBrightnessDown".action = {
              spawn = [
                "~/.config/hyprextra/scripts/kbbacklight.sh"
                "--dec"
              ];
            };
          };
        };
      };

      xdg = {
        mimeApps = {
          associations.added = {
            "text/html" = [ "firefox.desktop" ];
            "x-scheme-handler/http" = [ "firefox.desktop" ];
            "x-scheme-handler/https" = [ "firefox.desktop" ];
            "x-scheme-handler/about" = [ "firefox.desktop" ];
            "x-scheme-handler/unknown" = [ "firefox.desktop" ];
          };

          defaultApplications = {
            "text/html" = [ "firefox.desktop" ];
            "x-scheme-handler/http" = [ "firefox.desktop" ];
            "x-scheme-handler/https" = [ "firefox.desktop" ];
            "x-scheme-handler/about" = [ "firefox.desktop" ];
            "x-scheme-handler/unknown" = [ "firefox.desktop" ];
          };
        };
      };
    };
  };
}
