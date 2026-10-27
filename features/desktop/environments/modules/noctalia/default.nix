{
  lib,
  config,
  pkgs,
  user,
  extraUsers ? [ ],
  ...
}:
let
  allUsers = [ user ] ++ extraUsers;
  cfg = config.desktop.environments.modules.noctalia;
  shell = config.desktop.environments.shell;
  u2f = config.hardware-profile.u2f.enable;

  # Compositor-aware graceful exits; see
  # ../../shell/session-actions.nix for why they are needed.
  sessionActions = [
    { action = "lock"; }
    {
      action = "logout";
      command = lib.getExe shell.sessionActions.logout;
    }
    { action = "lock_and_suspend"; }
    {
      action = "reboot";
      command = lib.getExe shell.sessionActions.reboot;
    }
    {
      action = "shutdown";
      command = lib.getExe shell.sessionActions.poweroff;
      variant = "destructive";
    }
  ];

  # Bar widget backed by ../../shell/nixos-deploy-state.nix. Installed into
  # Noctalia's local plugin directory, which it scans as a built-in source.
  deployStatePlugin = "noctalia/plugins/nixos-deploy-state";
  deployStateFiles = {
    "${deployStatePlugin}/plugin.toml".source = ./plugins/nixos-deploy-state/plugin.toml;
    "${deployStatePlugin}/widget.luau".source =
      pkgs.replaceVars ./plugins/nixos-deploy-state/widget.luau
        {
          deployState = lib.getExe shell.nixosDeployState;
        };
  };

  settingsAppId = "dev.noctalia.Noctalia";

  # IPC binds, rendered for both compositors. Panel binds also move the
  # pointer onto the panel under Hyprland (see hyprlandConfig).
  panelBinds = {
    launcher = {
      hyprland = "SUPER + Space";
      niri = "Mod+Space";
      command = "noctalia msg panel-toggle launcher";
    };
    controlCenter = {
      hyprland = "SUPER + S";
      niri = "Mod+S";
      command = "noctalia msg panel-toggle control-center";
    };
    clipboard = {
      hyprland = "SUPER + V";
      niri = "Mod+V";
      command = "noctalia msg panel-toggle clipboard";
    };
  };
  # ALT+Tab holds the switcher open while ALT stays down.
  actionBinds = {
    settings = {
      hyprland = "SUPER + comma";
      niri = "Mod+Comma";
      command = "noctalia msg settings-toggle";
    };
    windowSwitcher = {
      hyprland = "ALT + Tab";
      niri = "Alt+Tab";
      command = "noctalia msg window-switcher hold";
    };
  };

  # Screen brightness on the focused monitor, usable on the lock screen and
  # repeating while held. Noctalia shows the OSD on every change. Unlike
  # `volume-osd`, `brightness-osd` requires an explicit value and cannot
  # re-show the current level, so at 0% and 100% the key gives no feedback.
  brightnessBinds = {
    XF86MonBrightnessUp = "noctalia msg brightness-up";
    XF86MonBrightnessDown = "noctalia msg brightness-down";
  };

  lua = builtins.toJSON;
  hyprlandConfig = ''
    -- Noctalia panels opened from a keybind: once the panel maps, move the
    -- pointer to its centre so it is where the eyes go. Bar clicks leave the
    -- pointer alone (it is already there). The request expires after a
    -- second or two so a toggle that closed a panel cannot move the pointer
    -- on a later, unrelated open. niri has no action to move the pointer.
    local noctaliaPanelRequestedAt = nil
    local function noctaliaPanel(cmd)
      return function()
        noctaliaPanelRequestedAt = os.time()
        hl.exec_cmd(cmd)
      end
    end
    hl.on("layer.opened", function(ls)
      if noctaliaPanelRequestedAt == nil or os.time() - noctaliaPanelRequestedAt > 1 then
        return
      end
      if ls.namespace ~= "noctalia-panel" and ls.namespace ~= "noctalia-attached-panel" then
        return
      end
      noctaliaPanelRequestedAt = nil
      hl.dispatch(hl.dsp.cursor.move({
        x = math.floor(ls.x + ls.w / 2),
        y = math.floor(ls.y + ls.h / 2),
      }))
    end)

    ${lib.concatMapStringsSep "\n" (b: "hl.bind(${lua b.hyprland}, noctaliaPanel(${lua b.command}))") (
      lib.attrValues panelBinds
    )}
    ${lib.concatMapStringsSep "\n" (
      b: "hl.bind(${lua b.hyprland}, hl.dsp.exec_cmd(${lua b.command}))"
    ) (lib.attrValues actionBinds)}
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (
        key: cmd: "hl.bind(${lua key}, hl.dsp.exec_cmd(${lua cmd}), { locked = true, repeating = true })"
      ) brightnessBinds
    )}

    hl.window_rule({
      match = { class = ${lua settingsAppId} },
      float = true,
      size = { 1080, 920 },
    })

    hl.layer_rule({
      name = "noctalia",
      match = {
        namespace = "^noctalia-(bar-.+|notification|dock|panel|attached-panel|osd|window-switcher)$",
      },
      no_anim = true,
      ignore_alpha = 0.5,
      blur = true,
      blur_popups = true,
    })
  '';

  settings = uname: {
    shell = {
      font_family = "SFProDisplay Nerd Font";
      telemetry_enabled = false;
      # Polkit agent. Authentication runs through the polkit-1 PAM service,
      # so fingerprint and U2F work there.
      polkit_agent = true;
      # Clipboard history. Its encryption key lives in the Secret Service
      # (gnome-keyring's default collection).
      clipboard_enabled = true;
      # Typing in niri's overview opens the launcher with what was typed.
      niri_overview_type_to_launch_enabled = true;
      session.actions = sessionActions;

      # Noctalia cannot place a panel by how it was opened, so the control
      # center floats just below the bar: under the widget when a bar widget
      # is clicked, centred along the bar when opened by keybind.
      panel = {
        control_center_placement = "floating";
        control_center_position = "auto";
        open_near_click_control_center = true;
      };
    };

    # Height is fixed (520 x ui_scale); only the width is configurable. With
    # the full sidebar the tabs carry labels as well as icons.
    control_center = {
      width = 1000;
      sidebar = "full";
      sidebar_section = "full";
    };

    # Built-in Catppuccin is Mocha with a mauve primary, matching the global
    # catppuccin accent. Templates stay off so Noctalia never rewrites GTK or
    # terminal colours that catppuccin/nix already owns.
    theme = {
      mode = "dark";
      source = "builtin";
      builtin = "Catppuccin";
      templates = {
        enable_builtin_templates = false;
        enable_community_templates = false;
      };
    };

    # Every monitor gets its own no-repeat shuffle over the whole nested
    # library. Noctalia remembers which images each monitor has shown in
    # ~/.local/state/noctalia/wallpaper_shuffle.json and repeats nothing
    # until all of them have been used.
    wallpaper = {
      enabled = true;
      fill_mode = "crop";
      transition = [ "fade" ];
      transition_duration = 700;
      directory = "/home/${uname}/Pictures/Background";
      per_monitor_directories = true;
      automation = {
        enabled = true;
        interval_seconds = 300;
        order = "random";
        recursive = true;
      };
    };

    # niri-only blurred overview copy of the wallpaper. Off because the niri
    # layer rules put the real wallpaper in the backdrop instead.
    backdrop.enabled = false;

    notification = {
      follow_focused_output = true;
      offset_x = 8;
      offset_y = 8;
    };

    osd = {
      position = "top_center";
      follow_focused_output = true;
    };

    # Noctalia authenticates against the `login` PAM stack and drives
    # fprintd itself. With a security key, Enter on an empty field starts
    # the pam_u2f touch prompt.
    lockscreen = {
      enabled = true;
      allow_empty_password = u2f;
    };

    # Lock, then monitors off, then suspend.
    idle = {
      behavior_order = [
        "lock"
        "screen-off"
        "suspend"
      ];
      behavior = {
        lock = {
          enabled = true;
          timeout = 300;
          action = "lock";
        };
        screen-off = {
          enabled = true;
          timeout = 600;
          action = "screen_off";
        };
        suspend = {
          enabled = true;
          timeout = 900;
          action = "suspend";
        };
      };
    };

    # Fixed schedule. Noctalia fades over the hour centred on each time.
    nightlight = {
      enabled = true;
      temperature_day = 6500;
      temperature_night = 5000;
    };

    location = {
      address = "Albuquerque, NM";
      custom_schedule = true;
      sunrise = "07:30";
      sunset = "18:00";
    };
    weather.enabled = true;

    plugins = {
      auto_update = "none";
      enabled = [ "fred/nixos-deploy-state" ];
    };

    bar = {
      order = [ "main" ];
      main = {
        position = "top";
        # Opaque, with a thin outline in the accent colour (mauve). No drop
        # shadow and no compositor blur, so nothing is drawn over the
        # wallpaper beside or below the bar.
        border = "primary";
        border_width = 1.0;
        shadow = false;
        compositor_blur = false;
        # Semibold labels (600); Noctalia defaults to 500.
        font_weight = 600;
        start = [
          "dashboard"
          "weather"
          "tray"
        ];
        center = [
          "workspaces"
          "active_window"
        ];
        end = [
          "media"
          "volume"
          "network"
          # Hides itself when the host has no battery.
          "battery"
          "caffeine"
          "deploy_state"
          "clock"
          "notifications"
        ];
      };
    };

    widget = {
      # Session menu behind a NixOS snowflake.
      dashboard = {
        type = "session";
        custom_image = "${pkgs.nixos-icons}/share/icons/hicolor/scalable/apps/nix-snowflake.svg";
        custom_image_colorize = true;
      };
      deploy_state.type = "fred/nixos-deploy-state:state";
      clock.format = "{:%H:%M:%S}";
      media.album_art_only = true;
      volume.show_label = false;
      network.show_label = false;
    };
  };
in
{
  options.desktop.environments.modules.noctalia = {
    enable = lib.mkEnableOption "Noctalia desktop shell (bar, OSD, notifications, wallpaper)";
  };

  config = lib.mkIf cfg.enable {
    desktop.environments.shell = {
      # Noctalia runs as a systemd user service, outside the logind session,
      # and falls back to XDG_SESSION_ID to find it. Without it Noctalia never
      # hears `loginctl lock-session` (SUPER+L, lid switch) and cannot resolve
      # the session for brightness or polkit. The compositor's environment
      # has it, so hand it to the user manager before restarting Noctalia.
      startupCommands = [
        "systemctl --user import-environment XDG_SESSION_ID && systemctl --user restart noctalia"
      ];
      commands = {
        # Noctalia only pops the OSD when the volume actually changes, so at
        # 0% or 100% a key press would show nothing. Show it explicitly.
        volumeUp = "noctalia msg volume-up 5 && noctalia msg volume-osd";
        volumeDown = "noctalia msg volume-down 5 && noctalia msg volume-osd";
        volumeMute = "noctalia msg volume-mute";
        micMute = "noctalia msg mic-mute";
        idleInhibitToggle = "noctalia msg caffeine-toggle";
      };
    };

    # The lock screen uses `login`, not a hyprlock-style dedicated service,
    # so the security key has to be accepted there. This also lets the key
    # satisfy a text-console login on this host.
    security.pam.services.login.u2fAuth = lib.mkIf u2f true;

    home-manager.users = lib.genAttrs allUsers (uname: {
      xdg.dataFile = deployStateFiles;

      # Noctalia's recommended binds and rules, kept identical across both
      # compositors.
      wayland.windowManager.hyprland.extraConfig = hyprlandConfig;

      programs.niri.settings = {
        binds =
          lib.mapAttrs' (_: b: lib.nameValuePair b.niri { action.spawn-sh = b.command; }) (
            panelBinds // actionBinds
          )
          // lib.mapAttrs (_: cmd: {
            action.spawn-sh = cmd;
            allow-when-locked = true;
          }) brightnessBinds;

        # Noctalia requests blur for its own surfaces. Turn off xray so the
        # blur samples what is really behind them, not just the wallpaper,
        # which otherwise shows through the rounded corners. The window
        # switcher does not request blur, so force it.
        layer-rules = [
          {
            matches = [
              { namespace = "^noctalia-(bar-[^\"]+|notification|dock|panel|attached-panel|osd)$"; }
            ];
            background-effect.xray = false;
          }
          {
            matches = [ { namespace = "^noctalia-window-switcher$"; } ];
            background-effect = {
              blur = true;
              xray = false;
            };
          }
          # Stationary wallpaper: it lives in niri's backdrop, so it stays put
          # while workspaces scroll and the overview shows it unblurred. This
          # needs Noctalia's own [backdrop] layer to stay disabled (its
          # default), or that blurred copy would cover the wallpaper.
          {
            matches = [ { namespace = "^noctalia-wallpaper"; } ];
            place-within-backdrop = true;
          }
        ];

        # Let the backdrop (and so the wallpaper) show through workspaces.
        layout.background-color = "transparent";
        overview.workspace-shadow.enable = false;

        # After the niri module's catch-all `open-maximized` rule, so this one
        # wins for the settings window.
        window-rules = lib.mkAfter [
          {
            matches = [ { app-id = "^${lib.escapeRegex settingsAppId}$"; } ];
            open-floating = true;
            open-maximized = false;
            default-column-width.fixed = 1080;
            default-window-height.fixed = 920;
          }
        ];
      };

      programs.noctalia = {
        enable = true;
        systemd.enable = true;
        settings = settings uname;
      };
    });
  };
}
