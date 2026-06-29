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

    # hyprshutdown: graceful Hyprland exit utility. It asks each running app
    # to close (and waits) before quitting the compositor, instead of letting
    # apps die when the compositor exits. The wayle dashboard dropdown's
    # logout/reboot/poweroff actions dispatch to it on Hyprland (see the
    # compositor-aware wrappers in the wayle module). Reboot/poweroff use its
    # `--post-cmd` to run `systemctl reboot`/`poweroff` after the graceful
    # exit completes.
    environment.systemPackages = [ pkgs.hyprshutdown ];

    # xdg-desktop-portal-hyprland does not implement the FileChooser interface,
    # and the implicit hyprland;gtk fallback chain does not reliably fall
    # through to the gtk backend for it — leaving rfd/Firefox/Flatpak native
    # file dialogs broken ("No such interface org.freedesktop.portal.
    # FileChooser"). Route FileChooser explicitly to the gtk backend (which is
    # always present via xdg.portal.extraPortals in common.nix) while keeping
    # screencast/screenshot on the hyprland backend. The `hyprland` config key
    # matches XDG_CURRENT_DESKTOP under this compositor.
    xdg.portal.config.hyprland = {
      default = [
        "hyprland"
        "gtk"
      ];
      "org.freedesktop.impl.portal.FileChooser" = [ "gtk" ];
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

      # The xdg-desktop-portal daemon discovers portal *definition* files
      # (`*.portal`) by scanning `xdg-desktop-portal/portals` under each
      # XDG_DATA_DIRS entry, and the per-user profile
      # (`/etc/profiles/per-user/<user>/share`) is on that path. home-manager's
      # `wayland.windowManager.hyprland` integration installs only
      # `xdg-desktop-portal-hyprland` into that profile, so the gtk backend's
      # `gtk.portal` definition is absent from the user profile. The
      # system-level `FileChooser=gtk` routing (above) then resolves to a
      # backend the daemon reports as "Requested gtk.portal is unrecognized",
      # and rfd/Firefox/Flatpak get "No such interface
      # org.freedesktop.portal.FileChooser". Installing the gtk portal here
      # places `gtk.portal` next to `hyprland.portal` in the user profile so
      # the routing resolves. The system-level `xdg.portal.extraPortals` entry
      # in common.nix keeps the backend's D-Bus/systemd activation wired up.
      home.packages = [ pkgs.xdg-desktop-portal-gtk ];

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

        # Migrated to the Lua API so catppuccin's `colors._var` local renders
        # correctly. All settings live in `extraConfig` as hand-written Lua
        # because (a) most of our keys (`exec-once`, `col.active_border`,
        # `$mainMod`, `binde`, etc.) are not valid Lua identifiers the HM
        # `settings` renderer can express, and (b) dispatchers are functions
        # in the Lua API (`hl.dsp.exec_cmd(...)`), not comma-separated
        # strings. Hosts add their own monitor/workspace/bind config via
        # `extraConfig` as well.
        configType = "lua";

        extraConfig = ''
          ----------------
          ---- LOCALS ----
          ----------------

          local mainMod = "SUPER"
          local fileManager = "yazi"
          local terminal = "freminal"
          local email = "thunderbird"
          local scripts = os.getenv("HOME") .. "/.config/hyprextra/scripts"

          ----------------
          ---- ENV    ----
          ----------------

          hl.env("QT_QPA_PLATFORMTHEME", "qt6ct")
          hl.env("XCURSOR_SIZE", "24")

          ----------------
          ---- MISC   ----
          ----------------

          hl.config({
            misc = {
              disable_splash_rendering = true,
              disable_hyprland_logo = true,
            },

            general = {
              gaps_in = 2,
              gaps_out = 2,
              border_size = 2,
              resize_on_border = true,
              col = {
                active_border = { colors = {"rgb(44475a)", "rgb(bd93f9)"}, angle = 90 },
                inactive_border = "rgba(44475aaa)",
                nogroup_border_active = { colors = {"rgb(bd93f9)", "rgb(44475a)"}, angle = 90 },
              },
            },

            input = {
              kb_layout = "us",
              follow_mouse = 1,
              numlock_by_default = true,
              repeat_delay = 250,
              repeat_rate = 35,
              touchpad = {
                natural_scroll = true,
                disable_while_typing = true,
                clickfinger_behavior = true,
                scroll_factor = 0.5,
              },
            },

            gestures = {
              workspace_swipe_distance = 700,
              workspace_swipe_cancel_ratio = 0.2,
              workspace_swipe_min_speed_to_force = 5,
              workspace_swipe_direction_lock = true,
              workspace_swipe_direction_lock_threshold = 0,
              workspace_swipe_create_new = true,
            },

            decoration = {
              shadow = {
                enabled = true,
                range = 60,
                offset = "1 2",
                color = "rgba(1E202966)",
                render_power = 3,
                scale = 0.97,
              },
            },

            group = {
              groupbar = {
                col = {
                  active = { colors = {"rgb(bd93f9)", "rgb(44475a)"}, angle = 90 },
                  inactive = "rgba(282a36dd)",
                },
              },
            },

            binds = {
              scroll_event_delay = 0,
            },

            animations = {
              enabled = true,
            },
          })

          --------------------
          ---- GESTURES   ----
          --------------------

          hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })
          hl.gesture({ fingers = 4, direction = "horizontal", action = "workspace" })

          --------------------
          ---- ANIMATIONS ----
          --------------------

          hl.curve("myBezier", { type = "bezier", points = { {0.05, 0.9}, {0.1, 1.05} } })

          hl.animation({ leaf = "windows",     enabled = true, speed = 7,  bezier = "myBezier" })
          hl.animation({ leaf = "windowsOut",  enabled = true, speed = 7,  bezier = "default", style = "popin 80%" })
          hl.animation({ leaf = "border",      enabled = true, speed = 10, bezier = "default" })
          hl.animation({ leaf = "borderangle", enabled = true, speed = 8,  bezier = "default" })
          hl.animation({ leaf = "fade",        enabled = true, speed = 7,  bezier = "default" })
          hl.animation({ leaf = "workspaces",  enabled = true, speed = 6,  bezier = "default" })

          --------------------
          ---- AUTOSTART  ----
          --------------------

          hl.on("hyprland.start", function()
            hl.exec_cmd("systemctl restart --user polkit-gnome-authentication-agent-1")
            hl.exec_cmd("gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'")
            hl.exec_cmd("gsettings set org.gnome.desktop.interface gtk-theme 'Catppuccin-GTK-Mauve-Dark'")
            hl.exec_cmd("systemctl restart --user wayle")
            hl.exec_cmd("systemctl restart --user sway-audio-idle-inhibit")
            hl.exec_cmd("systemctl restart --user hypridle")
            hl.exec_cmd("systemctl restart --user network-manager-applet")
            hl.exec_cmd("systemctl restart --user udiskie-agent")
            hl.exec_cmd("systemctl restart --user solaar")
            hl.exec_cmd("blueman-applet")
            hl.exec_cmd("hyprsunset")
            hl.exec_cmd("sleep 5 && 1password --silent")
          end)

          --------------------
          ---- KEYBINDS   ----
          --------------------

          hl.bind(mainMod .. " + F",         hl.dsp.exec_cmd("firefox"))
          hl.bind(mainMod .. " + E",         hl.dsp.exec_cmd(email))
          hl.bind(mainMod .. " + T",         hl.dsp.exec_cmd(terminal))
          hl.bind(mainMod .. " + SHIFT + T", hl.dsp.exec_cmd("wezterm start -- bash"))
          hl.bind(mainMod .. " + CTRL + T",  hl.dsp.exec_cmd("freminal --shell bash"))
          hl.bind(mainMod .. " + A",         hl.dsp.exec_cmd("freminal --hide-menu-bar yazi"))
          hl.bind(mainMod .. " + S",         hl.dsp.exec_cmd("wayle idle toggle --indefinite"))
          hl.bind("ALT + SPACE",             hl.dsp.exec_cmd("vicinae toggle"))
          hl.bind(mainMod .. " + C",         hl.dsp.window.close())
          hl.bind(mainMod .. " + M",         hl.dsp.exit())
          hl.bind(mainMod .. " + L",         hl.dsp.exec_cmd(scripts .. "/pauseandsleep.sh"))

          -- Move windows with mainMod + arrow keys
          hl.bind(mainMod .. " + left",  hl.dsp.window.move({ direction = "l" }))
          hl.bind(mainMod .. " + right", hl.dsp.window.move({ direction = "r" }))
          hl.bind(mainMod .. " + up",    hl.dsp.window.move({ direction = "u" }))
          hl.bind(mainMod .. " + down",  hl.dsp.window.move({ direction = "d" }))

          -- Move focus with mainMod + SHIFT + arrow keys
          hl.bind(mainMod .. " + SHIFT + left",  hl.dsp.focus({ direction = "l" }))
          hl.bind(mainMod .. " + SHIFT + right", hl.dsp.focus({ direction = "r" }))
          hl.bind(mainMod .. " + SHIFT + up",    hl.dsp.focus({ direction = "u" }))
          hl.bind(mainMod .. " + SHIFT + down",  hl.dsp.focus({ direction = "d" }))

          hl.bind("Print",                 hl.dsp.exec_cmd("grim"))
          hl.bind(mainMod .. " + Print",   hl.dsp.exec_cmd("grim -g \"$(slurp)\""))

          -- Switch workspaces with mainMod + [0-9]
          for i = 1, 10 do
            local key = i % 10 -- 10 maps to key 0
            hl.bind(mainMod .. " + " .. key,           hl.dsp.focus({ workspace = i }))
            hl.bind(mainMod .. " + SHIFT + " .. key,   hl.dsp.window.move({ workspace = i }))
          end

          -- Scroll through workspaces with mainMod + scroll / mouse forward/back
          hl.bind(mainMod .. " + mouse_down", hl.dsp.focus({ workspace = "e+1" }))
          hl.bind(mainMod .. " + mouse_up",   hl.dsp.focus({ workspace = "e-1" }))
          hl.bind(mainMod .. " + mouse:276",  hl.dsp.focus({ workspace = "e-1" })) -- Back
          hl.bind(mainMod .. " + mouse:275",  hl.dsp.focus({ workspace = "e+1" })) -- Forward

          -- Multimedia (locked + repeating)
          hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("wayle audio output-volume +5"), { locked = true, repeating = true })
          hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("wayle audio output-volume -5"), { locked = true, repeating = true })
          hl.bind("XF86AudioMute",        hl.dsp.exec_cmd("wayle audio output-mute"),      { locked = true, repeating = true })
          hl.bind("XF86AudioMicMute",     hl.dsp.exec_cmd("wayle audio input-mute"),       { locked = true, repeating = true })
          hl.bind("XF86AudioPlay",        hl.dsp.exec_cmd("playerctl play-pause"),               { locked = true, repeating = true })
          hl.bind("XF86AudioPause",       hl.dsp.exec_cmd("playerctl play-pause"),               { locked = true, repeating = true })
          hl.bind("XF86AudioNext",        hl.dsp.exec_cmd("playerctl next"),                     { locked = true, repeating = true })
          hl.bind("XF86AudioPrev",        hl.dsp.exec_cmd("playerctl previous"),                 { locked = true, repeating = true })

          hl.bind("XF86KbdBrightnessUp",   hl.dsp.exec_cmd(scripts .. "/kbbacklight.sh --inc"), { locked = true, repeating = true })
          hl.bind("XF86KbdBrightnessDown", hl.dsp.exec_cmd(scripts .. "/kbbacklight.sh --dec"), { locked = true, repeating = true })
          hl.bind("XF86SelectiveScreenshot",       hl.dsp.exec_cmd("grim -g \"$(slurp)\""),             { locked = true, repeating = true })
          hl.bind("XF86Display",                   hl.dsp.exec_cmd(scripts .. "/pauseandsleep.sh"),     { locked = true, repeating = true })
          hl.bind("code:248",                      hl.dsp.exec_cmd(terminal),                           { locked = true, repeating = true })
          hl.bind("XF86Favorites",                 hl.dsp.exec_cmd("fuzzel"),                           { locked = true, repeating = true })
          hl.bind(mainMod .. " + XF86MonBrightnessUp",   hl.dsp.exec_cmd(scripts .. "/kbbacklight.sh --inc"), { locked = true, repeating = true })
          hl.bind(mainMod .. " + XF86MonBrightnessDown", hl.dsp.exec_cmd(scripts .. "/kbbacklight.sh --dec"), { locked = true, repeating = true })

          -- Move/resize windows with mainMod + LMB/RMB and dragging
          hl.bind(mainMod .. " + mouse:272", hl.dsp.window.drag(),   { mouse = true })
          hl.bind(mainMod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

          -- Lock lid on close
          hl.bind("switch:off:Lid Switch", hl.dsp.exec_cmd(scripts .. "/pauseandsleep.sh"), { locked = true })
        '';
      };

    });
  };
}
