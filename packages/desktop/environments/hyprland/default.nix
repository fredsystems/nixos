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
  cfg = config.desktop.environments.hyprland;
in
{
  options.desktop.environments.hyprland = {
    enable = mkOption {
      description = "Install Hyprland desktop environment.";
      default = false;
    };
  };

  config = mkIf cfg.enable {
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

    # systemd = {
    #   user.services.polkit-agent-helper-1 = {
    #     description = "polkit-agent-helper-1";
    #     wantedBy = [ "graphical-session.target" ];
    #     wants = [ "graphical-session.target" ];
    #     after = [ "graphical-session.target" ];
    #     serviceConfig = {
    #       Type = "simple";
    #       ExecStart = "/run/wrappers/bin/polkit-agent-helper-1";
    #       Restart = "on-failure";
    #       RestartSec = 1;
    #       TimeoutStopSec = 10;
    #     };
    #   };
    #   settings.Manager = {
    #     DefaultTimeoutStopSec = "10s";
    #   };
    #   # extraConfig = ''
    #   #   DefaultTimeoutStopSec=10s
    #   # '';
    # };

    programs.hyprland = {
      # Install the packages from nixpkgs
      enable = true;
      # Whether to enable XWayland
      xwayland.enable = true;
    };

    home-manager.users.${username} = {
      imports = [ ../modules/xdg-mime-common.nix ];

      home.packages = with pkgs; [
        networkmanagerapplet
      ];

      catppuccin.hyprland.enable = true;

      services.network-manager-applet.enable = true;
      # services.hypridle = {
      #   enable = true;

      #   settings = {
      #     general = {
      #       ignore_dbus_inhibit = false;
      #       ignore_systemd_inhibit = false;
      #     };
      #   };
      # };

      # gtk = {
      #   enable = true;
      #   gtk3.extraConfig = {
      #     gtk-application-prefer-dark-theme = 1;
      #   };

      #   gtk4.extraConfig = {
      #     gtk-application-prefer-dark-theme = 1;
      #   };

      #   theme = {
      #     name = "Catppuccin-GTK-Purple-Dark";
      #     # + optionalString (cfg.gtk.size == "compact") "-Compact"
      #     # + optionalString (flavorTweak != "") (mkSuffix flavorTweak);
      #     package = pkgs.magnetic-catppuccin-gtk.override {
      #       accent = [ "purple" ];
      #       shade = "dark";
      #       # inherit (cfg.gtk) size;
      #       # tweaks = cfg.gtk.tweaks ++ optional (flavorTweak != "") flavorTweak;
      #     };
      #   };
      # };

      wayland.windowManager.hyprland = {
        enable = true;

        settings = {
          "$mainMod" = "SUPER";
          "$fileManager" = "yazi";
          "$terminal" = "wezterm";
          "$email" = "thunderbird";

          env = [
            "QT_QPA_PLATFORMTHEME,qt6ct"
            "XCURSOR_SIZE, 24"
            # "GTK_THEME, adw-gtk3-dark"
          ];

          misc = [
            "disable_splash_rendering = true"
            "disable_hyprland_logo = true"
          ];

          exec = [

          ];

          exec-once = [
            "systemctl stop --user swaync"
            "systemctl restart --user polkit-gnome-authentication-agent-1"
            "gsettings set org.gnome.desktop.interface color-scheme \"prefer-dark\""
            "gsettings set org.gnome.desktop.interface gtk-theme \"Catppuccin-GTK-Mauve-Dark\""
            "~/.config/hyprextra/scripts/background.sh"
            "systemctl restart --user fredbar"
            "systemctl restart --user sway-audio-idle-inhibit"
            "systemctl restart --user user-sleep-hook"
            "systemctl restart --user one-password-agent"
            "systemctl restart --user network-manager-applet"
            "systemctl restart --user udiskie-agent"
            "systemctl restart --user bluetooth-agent"
            "blueman-applet"
          ];

          exec-shutdown = [
            "systemctl stop --user network-manager-applet"
            "systemctl stop --user bluetooth-agent"
            "systemctl stop --user udiskie-agent"
            "systemctl stop --user one-password-agent"
            "systemctl stop --user sway-audio-idle-inhibit"
            "systemctl stop --user user-sleep-hook"
            "systemctl stop --user polkit-gnome-authentication-agent-1"
            "systemctl stop --user fredbar"
          ];

          general = {
            "gaps_in" = 2;
            "gaps_out" = 2;
            "col.active_border" = "rgb(44475a) rgb(bd93f9) 90deg";
            "col.inactive_border" = "rgba(44475aaa)";

            "col.nogroup_border_active" = "rgb(bd93f9) rgb(44475a) 90deg";
            border_size = 2;
            resize_on_border = true;
          };

          input = {
            kb_layout = "us";
            follow_mouse = 1;
            numlock_by_default = true;
            repeat_delay = 250;
            repeat_rate = 35;

            touchpad = {
              natural_scroll = "yes";
              disable_while_typing = true;
              clickfinger_behavior = true;
              scroll_factor = 0.5;
            };
          };

          gesture = [
            "3, horizontal, workspace"
            "4, horizontal, workspace"
          ];

          gestures = {
            # workspace_swipe = true;
            workspace_swipe_distance = 700;
            # workspace_swipe_fingers = 4;
            workspace_swipe_cancel_ratio = 0.2;
            workspace_swipe_min_speed_to_force = 5;
            workspace_swipe_direction_lock = true;
            workspace_swipe_direction_lock_threshold = 0;
            workspace_swipe_create_new = true;
          };

          decoration = {
            shadow = {
              enabled = true;
              range = 60;
              offset = "1 2";
              color = "rgba(1E202966)";
              render_power = 3;
              scale = 0.97;
            };
          };

          animations = {
            enabled = "yes";

            bezier = "myBezier, 0.05, 0.9, 0.1, 1.05";

            animation = [
              "windows, 1, 7, myBezier"
              "windowsOut, 1, 7, default, popin 80%"
              "border, 1, 10, default"
              "borderangle, 1, 8, default"
              "fade, 1, 7, default"
              "workspaces, 1, 6, default"
            ];
          };

          group = {
            groupbar = {
              "col.active" = "rgb(bd93f9) rgb(44475a) 90deg";
              "col.inactive" = "rgba(282a36dd)";
            };
          };

          binds = {
            scroll_event_delay = 0;
          };

          # windowrulev2 = "bordercolor rgb(ff5555),xwayland:1";
          # check if window is xwayland

          bind = [
            "$mainMod, F, exec, firefox"
            "$mainMod, E, exec, $email"
            "$mainMod, T, exec, $terminal"
            "$mainMod SHIFT, T, exec, $terminal start -- bash"
            "$mainMod, A, exec, wezterm start --class yazi -- yazi"
            "$mainMod, S, exec, ~/.config/hyprextra/scripts/idleinhibit.sh"
            "ALT, SPACE, exec, vicinae toggle"
            "$mainMod, C, killactive"
            "$mainMod, M, exit"
            "$mainMod, L, exec, ~/.config/hyprextra/scripts/pauseandsleep.sh"

            # Move windows with mainMod + arrow keys
            "$mainMod, left, movewindow, l"
            "$mainMod, right, movewindow, r"
            "$mainMod, up, movewindow, u"
            "$mainMod, down, movewindow, d"

            # Move focus with mainMod + SHIFT + arrow keys
            "$mainMod SHIFT, left, movefocus, l"
            "$mainMod SHIFT, right, movefocus, r"
            "$mainMod SHIFT, up, movefocus, u"
            "$mainMod SHIFT, down, movefocus, d"

            ", Print, exec, grim"
            "$mainMod, Print, exec, grim -g \"$(slurp)\""

            # Switch workspaces with mainMod + [0-9]
            "$mainMod, 1, workspace, 1"
            "$mainMod, 2, workspace, 2"
            "$mainMod, 3, workspace, 3"
            "$mainMod, 4, workspace, 4"
            "$mainMod, 5, workspace, 5"
            "$mainMod, 6, workspace, 6"
            "$mainMod, 7, workspace, 7"
            "$mainMod, 8, workspace, 8"
            "$mainMod, 9, workspace, 9"
            "$mainMod, 0, workspace, 10"

            # Move active window to a workspace with mainMod + SHIFT + [0-9]
            "$mainMod SHIFT, 1, movetoworkspace, 1"
            "$mainMod SHIFT, 2, movetoworkspace, 2"
            "$mainMod SHIFT, 3, movetoworkspace, 3"
            "$mainMod SHIFT, 4, movetoworkspace, 4"
            "$mainMod SHIFT, 5, movetoworkspace, 5"
            "$mainMod SHIFT, 6, movetoworkspace, 6"
            "$mainMod SHIFT, 7, movetoworkspace, 7"
            "$mainMod SHIFT, 8, movetoworkspace, 8"
            "$mainMod SHIFT, 9, movetoworkspace, 9"
            "$mainMod SHIFT, 0, movetoworkspace, 10"

            # Scroll through existing workspaces with mainMod + scroll
            "$mainMod, mouse_down, workspace, e+1"
            "$mainMod, mouse_up, workspace, e-1"

            # Scroll through existing workspaces with mainMod + scroll
            "$mainMod, mouse_down, workspace, e+1"
            "$mainMod, mouse_up, workspace, e-1"
            "$mainMod, mouse_down, workspace, e-1"
            "$mainMod, mouse_up, workspace, e+1"

            "$mainMod, mouse:276, workspace, e-1" # Back button
            "$mainMod, mouse:275, workspace, e+1" # Forward button
          ];

          binde = [
            ", XF86AudioRaiseVolume, exec, ~/.config/hyprextra/scripts/volume.sh --inc "
            ", XF86AudioLowerVolume, exec, ~/.config/hyprextra/scripts/volume.sh --dec "
            ", XF86AudioMute, exec, ~/.config/hyprextra/scripts/volume.sh --toggle"
            ", XF86AudioMicMute, exec, ~/.config/hyprextra/scripts/volume.sh --toggle-mic"
            ", XF86AudioPlay, exec, playerctl play-pause"
            ", XF86AudioPause, exec, playerctl play-pause"
            ", XF86AudioNext, exec, playerctl next"
            ", XF86AudioPrev, exec, playerctl previous"
            ", XKB_KEY_XF86KbdBrightnessUp, exec, ~/.config/hyprextra/scripts/kbbacklight.sh --inc"
            ", XKB_KEY_XF86KbdBrightnessDown, exec, ~/.config/hyprextra/scripts/kbbacklight.sh --dec"
            ", XF86SelectiveScreenshot, exec, grim -g \"$(slurp)\""
            ", XF86Display, exec, ~/.config/hyprextra/scripts/pauseandsleep.sh"
            ", code:248, exec, $terminal"
            ", XF86Favorites, exec, fuzzel"
            "$mainMod, XF86MonBrightnessUp, exec, ~/.config/hyprextra/scripts/kbbacklight.sh --inc"
            "$mainMod, XF86MonBrightnessDown, exec, ~/.config/hyprextra/scripts/kbbacklight.sh --dec"
          ];

          bindm = [
            # Move/resize windows with mainMod + LMB/RMB and dragging
            "$mainMod, mouse:272, movewindow"
            "$mainMod, mouse:273, resizewindow"
          ];

          bindl = [
            # Lock lid on close
            ",switch:off:Lid Switch, exec, ~/.config/hyprextra/scripts/pauseandsleep.sh"
          ];
        };
      };

    };
  };
}
