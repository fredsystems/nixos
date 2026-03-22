{
  lib,
  pkgs,
  config,
  user,
  hmlib,
  extraUsers ? [ ],
  ...
}:
let
  allUsers = [ user ] ++ extraUsers;
  cfg = config.desktop.environments.hyprland;
  inherit (config.desktop.environments.common) waitForWayland;
in
{
  options.desktop.environments.hyprland = {
    enable = lib.mkEnableOption "Hyprland desktop environment";
  };

  config = lib.mkIf cfg.enable {

    programs.hyprland = {
      # Install the packages from nixpkgs
      enable = true;
      # Whether to enable XWayland
      xwayland.enable = true;
    };

    # xdg-desktop-portal-hyprland segfaults when Hyprland exits (a bug in xdph
    # itself), then restarts 6 times in rapid succession against a dead
    # compositor and hits the burst limit — leaving it permanently dead for the
    # next login. overrideStrategy = "asDropin" merges these settings into the
    # NixOS-managed unit without replacing it, giving it a RestartSec so the
    # burst limit is never tripped, and an ExecStartPre so on re-login it waits
    # for the Wayland socket before trying to connect.
    systemd.user.services.xdg-desktop-portal-hyprland = {
      overrideStrategy = "asDropin";
      unitConfig = {
        StartLimitIntervalSec = 0;
      };
      serviceConfig = {
        RestartSec = "3s";
        ExecStartPre = waitForWayland;
      };
    };

    home-manager.users = lib.genAttrs allUsers (_: {

      # wayland.windowManager.hyprland generates a broken stub unit at
      # ~/.config/systemd/user/xdg-desktop-portal-hyprland.service that only
      # contains our ExecStartPre and has no ExecStart — causing systemd to
      # report bad-setting and refuse to start it, shadowing the real unit in
      # /etc/systemd/user/. Remove it after home-manager places it so only the
      # system-level unit (with our overrideStrategy drop-in) is used.
      home.activation.removePortalHyprlandStub = hmlib.hm.dag.entryAfter [ "writeBoundary" ] ''
        rm -f ~/.config/systemd/user/xdg-desktop-portal-hyprland.service
        rm -f ~/.config/systemd/user/xdg-desktop-portal-hyprland.service.d/wait-for-wayland.conf
        rmdir --ignore-fail-on-non-empty ~/.config/systemd/user/xdg-desktop-portal-hyprland.service.d 2>/dev/null || true
        $DRY_RUN_CMD ${pkgs.systemd}/bin/systemctl --user daemon-reload || true
      '';

      catppuccin.hyprland.enable = true;

      wayland.windowManager.hyprland = {
        enable = true;

        settings = {
          "$mainMod" = "SUPER";
          "$fileManager" = "yazi";
          "$terminal" = "freminal";
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
            "systemctl restart --user hypridle"
            "systemctl restart --user network-manager-applet"
            "systemctl restart --user udiskie-agent"
            "systemctl restart --user solaar"
            "blueman-applet"
            "sleep 5 && 1password --silent"
          ];

          exec-shutdown = [
            "systemctl stop --user network-manager-applet"
            "systemctl stop --user udiskie-agent"
            "systemctl stop --user solaar"
            "systemctl stop --user sway-audio-idle-inhibit"
            "systemctl stop --user hypridle"
            "systemctl stop --user polkit-gnome-authentication-agent-1"
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
            "$mainMod SHIFT, T, exec, wezterm start -- bash"
            "$mainMod, A, exec, freminal --hide-menu-bar yazi"
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

    });
  };
}
