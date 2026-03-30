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
  cfg = config.desktop.environments.common;
  dpmsScript = "~/.config/hyprextra/scripts/dpms.sh";

  # Shared theme definition used for both gtk.theme (GTK3) and
  # gtk.gtk4.theme.  Home-manager >=26.05 no longer auto-inherits the GTK3
  # theme for GTK4, so we set both explicitly.
  catppuccinGtkTheme = {
    name = "Catppuccin-GTK-Mauve-Dark";
    package = pkgs.magnetic-catppuccin-gtk.override {
      accent = [ "mauve" ];
      shade = "dark";
    };
  };
in
{
  options.desktop.environments.common = {
    enable = lib.mkEnableOption "shared Wayland compositor infrastructure (keyring, gvfs, polkit, portal, etc.)";

    # Shared helper exposed for compositor and bar modules that need to wait
    # for the Wayland socket before starting a service.
    waitForWayland = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "${lib.getExe' pkgs.bash "bash"} -c 'until [ -S \"$\{XDG_RUNTIME_DIR}/wayland-1\" ]; do sleep 0.5; done'";
      description = "Shell command that blocks until the Wayland socket exists.";
    };
  };

  config = lib.mkIf cfg.enable {

    # ── SDDM display manager ────────────────────────────────────────────────
    # Shared by all Wayland compositors (Hyprland, Niri).
    # The catppuccin NixOS module (catppuccin.sddm) sets the theme and
    # installs the theme package automatically; we only need to supply the
    # Qt 6 SDDM build it requires and any SDDM-level knobs.
    services.displayManager.sddm = {
      enable = true;
      package = pkgs.kdePackages.sddm;
      wayland.enable = true;

      settings = {
        Theme = {
          CursorTheme = "catppuccin-mocha-lavender-cursors";
          CursorSize = 24;
        };

        General = {
          RememberLastSession = true;
          RememberLastUser = true;
        };
      };
    };

    # ── Catppuccin SDDM theme options ────────────────────────────────────────
    # Inherits flavor (mocha) and accent (lavender) from the global
    # catppuccin settings.  catppuccin.enable = true auto-enables this.
    catppuccin.sddm = {
      enable = true;
      font = "SFProDisplay Nerd Font";
      fontSize = "12";
      loginBackground = true;
      userIcon = true;
    };

    # ── Shared compositor utility packages ───────────────────────────────────
    # Used by both Hyprland and Niri; compositor-specific binaries stay in
    # their own modules.
    users.users = lib.genAttrs allUsers (_: {
      packages = with pkgs; [
        # File manager + supporting libraries
        nautilus
        gvfs
        gnome.gvfs
        baobab

        # Media / file viewers used in xdg-mime-common.nix default associations
        gthumb
        sushi # Spacebar previewer (used inside Nautilus)
        gimp
        gparted

        # Screenshot / screen capture
        grim
        hyprshot
        slurp

        # Idle / lock / sleep
        hypridle
        hyprlock

        # Media controls (playerctl keybinds shared across both compositors)
        playerctl

        # Brightness
        brightnessctl

        # Notifications from scripts
        libnotify

        # Bluetooth applet
        blueman

        # Removable media
        udiskie
        udisks

        # System tray support
        libappindicator-gtk3

        # Wallpaper
        hyprpaper

        # Misc Wayland utilities
        wev

        # xdg-open — needed by udiskie for file manager integration and
        # generally required by any app that opens URLs/files via xdg-open
        xdg-utils

        # Shared compositor utilities (polkit agent, picker, audio idle inhibit)
        hyprpolkitagent
        hyprpicker
        sway-audio-idle-inhibit
        networkmanagerapplet
      ];
    });

    home-manager.users = lib.genAttrs allUsers (_: {
      imports = [ ./modules/xdg-mime-common.nix ];

      # ── User avatar (.face) ───────────────────────────────────────────────
      # Deployed to ~/.face so that SDDM and any greeter that respects the
      # freedesktop face icon convention picks it up automatically.
      home.file.".face" = {
        source = ./assets/face.png;
      };

      gtk = {
        enable = true;
        gtk3.extraConfig = {
          gtk-application-prefer-dark-theme = 1;
        };
        gtk4 = {
          extraConfig = {
            gtk-application-prefer-dark-theme = 1;
          };
          # HM >=26.05 no longer inherits gtk.theme for GTK4 by default.
          # Explicitly set it to preserve catppuccin theming for
          # GTK4/libadwaita apps (Nautilus, etc.).
          theme = catppuccinGtkTheme;
        };
        theme = catppuccinGtkTheme;
      };

      # ── Shared catppuccin/hyprlock settings ────────────────────────────────
      catppuccin = {
        gtk.icon.enable = true;
        hyprlock.enable = true;
      };

      programs.hyprlock.enable = true;

      # ── Wallpaper (hyprpaper) ──────────────────────────────────────────────
      # Shared hyprpaper config for both Hyprland and Niri.
      # Cycles through ~/Pictures/Background every 5 minutes in random order.
      #
      # ── Idle management (hypridle) ─────────────────────────────────────────
      # Single shared hypridle definition for both Hyprland and Niri.
      # DPMS on/off is delegated to dpms.sh, which probes the active compositor
      # at runtime via hyprctl / niri IPC — so the correct command is always
      # issued regardless of which compositor packages are installed on the host.
      services = {
        hyprpaper = {
          enable = true;
          settings = {
            splash = false;
            ipc = true;
            wallpaper = [
              {
                monitor = "";
                path = "~/Pictures/Background";
                fit_mode = "cover";
                timeout = 300;
              }
            ];
          };
        };

        network-manager-applet.enable = true;

        hypridle = {
          enable = true;
          settings = {
            general = {
              lock_cmd = "hyprlock";
              before_sleep_cmd = "hyprlock";
              after_sleep_cmd = "${dpmsScript} on";
            };

            listener = [
              {
                # Lock the screen after 5 minutes of inactivity.
                timeout = 300;
                on-timeout = "hyprlock";
              }
              {
                # Power off monitors after 10 minutes of inactivity.
                # dpms.sh detects whether Hyprland or Niri is running and
                # issues the appropriate compositor command.
                timeout = 600;
                on-timeout = "${dpmsScript} off";
                on-resume = "${dpmsScript} on";
              }
              {
                # Suspend the system after 15 minutes of inactivity.
                timeout = 900;
                on-timeout = "systemctl suspend";
              }
            ];
          };
        };
      };
    });

    services = {
      # ── Keyring ──────────────────────────────────────────────────────────────
      gnome.gnome-keyring.enable = true;

      # ── Virtual filesystem / trash / network mounts ────────────────────────
      gvfs.enable = true;

      # ── Power state information ───────────────────────────────────────────────
      upower.enable = lib.mkForce true;
    };

    # ── dconf ──────────────────────────────────────────────────────────────────
    programs.dconf.enable = true;

    # ── Polkit authentication agent + SDDM cursor package ────────────────────
    environment.systemPackages = with pkgs; [
      polkit_gnome
      glib
      gsettings-desktop-schemas

      # Catppuccin cursor theme – needed system-wide so the SDDM greeter
      # (which runs as the sddm user) can resolve the CursorTheme setting.
      catppuccin-cursors.mochaLavender
    ];

    environment.sessionVariables.GSETTINGS_SCHEMA_DIR = "${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}/glib-2.0/schemas";

    # ── XDG desktop portals ────────────────────────────────────────────────────
    xdg.portal = {
      enable = true;
      extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
      config.common.default = "*";
    };

    # ── Nautilus file manager ──────────────────────────────────────────────────
    programs.nautilus-open-any-terminal = {
      enable = true;
      terminal = "wezterm";
    };

    # ── Desktop environment helper modules ─────────────────────────────────────
    desktop.environments.modules.enable = true;

    # ── Polkit agent user service ──────────────────────────────────────────────
    systemd.user.services.polkit-gnome-authentication-agent-1 = {
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
  };
}
