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

  # Compositor-aware graceful exits shared with wayle; see
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

  settings = uname: {
    shell = {
      font_family = "SFProDisplay Nerd Font";
      telemetry_enabled = false;
      # Replaces polkit-gnome. Authentication still runs through the
      # polkit-1 PAM service, so fingerprint and U2F behave as before.
      polkit_agent = true;
      # Replaces cliphist. The history's encryption key lives in the Secret
      # Service (gnome-keyring's default collection).
      clipboard_enabled = true;
      session.actions = sessionActions;
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

    # Same timings hypridle used: lock, then monitors off, then suspend.
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

    # Fixed schedule matching the old hyprsunset profile. Noctalia fades over
    # the hour centred on each time.
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
        # Opaque, with a thin outline in the accent colour (mauve).
        border = "primary";
        border_width = 1.0;
        # wayle's bar labels are semibold (600); Noctalia defaults to 500. With
        # our SF Pro build only Regular and Bold resolve under the family name,
        # so 500 renders Regular and 600 renders Bold, which is what wayle showed.
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
      # Session menu behind a NixOS snowflake, like wayle's dashboard button.
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

      # Same chord cliphist + fuzzel use on wayle hosts.
      wayland.windowManager.hyprland.extraConfig = ''
        hl.bind("SUPER + V", hl.dsp.exec_cmd("noctalia msg panel-toggle clipboard"))
      '';

      programs.noctalia = {
        enable = true;
        systemd.enable = true;
        settings = settings uname;
      };
    });
  };
}
