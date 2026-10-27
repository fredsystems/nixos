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

  # Shared theme definition used for both gtk.theme (GTK3) and
  # gtk.gtk4.theme.  Home-manager >=26.05 no longer auto-inherits the GTK3
  # theme for GTK4, so we set both explicitly.
  #
  # Upstream catppuccin/gtk build. This replaces `magnetic-catppuccin-gtk`,
  # which was removed from nixpkgs because it depended on
  # `gtk-engine-murrine` (unmaintained, GTK 2 only). The derivation names
  # its output directory `<theme>-<flavor>-<accent>-<size>`, hence
  # `catppuccin-mocha-mauve-standard`; keep `catppuccinGtkThemeName` and
  # the override arguments in sync.
  catppuccinGtkThemeName = "catppuccin-mocha-mauve-standard";
  catppuccinGtkTheme = {
    name = catppuccinGtkThemeName;
    package = pkgs.catppuccin-gtk.override {
      accents = [ "mauve" ];
      variant = "mocha";
      size = "standard";
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

    # Exposed so compositor modules (and the GNOME shell user-theme) can name
    # the GTK theme without duplicating the string that has to match the
    # directory produced by the `catppuccin-gtk` derivation.
    gtkThemeName = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = catppuccinGtkThemeName;
      description = "Directory name of the catppuccin GTK theme installed for desktop users.";
    };
  };

  config = lib.mkIf cfg.enable {
    # ── Login screen: noctalia-greeter on greetd ───────────────────────────
    # greetd's PAM service is a substack of `login`, so what is configured
    # there (the gnome-keyring unlock, U2F from ./modules/noctalia, Daytona's
    # fingerprint opt-out) applies to the greeter as well.
    services.displayManager.noctalia-greeter = {
      enable = true;
      # Settings -> Security -> Noctalia Greeter -> Sync in the shell copies
      # the wallpaper and monitor layout here without an admin prompt.
      passwordlessSyncUsers = allUsers;
      cursorTheme = {
        package = pkgs.catppuccin-cursors.mochaMauve;
        name = "catppuccin-mocha-mauve-cursors";
      };
      settings = {
        # Open on the password step; the greeter itself remembers the last
        # session picked, like SDDM's RememberLastSession did.
        user.default = user;
        # Pinned, so a synced palette never replaces it.
        appearance = {
          scheme = "Catppuccin";
          theme_mode = "dark";
          font_family = "SFProDisplay Nerd Font";
        };
        cursor.size = 24;
        keyboard = {
          layout = "us";
          numlock = true;
        };
        # Same as the lock screen: Enter on an empty field starts the
        # security-key touch prompt.
        auth.allow_empty_password = config.hardware-profile.u2f.enable;
      };
    };

    # catppuccin.enable turns this on; there is no SDDM to theme.
    catppuccin.sddm.enable = false;

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

        # Lock screen
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

        # Misc Wayland utilities
        wev

        # xdg-open — needed by udiskie for file manager integration and
        # generally required by any app that opens URLs/files via xdg-open
        xdg-utils

        # Shared compositor utilities (picker, audio idle inhibit)
        hyprpicker
        sway-audio-idle-inhibit
        networkmanagerapplet
      ];
    });

    home-manager.users = lib.genAttrs allUsers (_: {
      imports = [ ./modules/xdg-mime-common.nix ];

      # ── User avatar (.face) ───────────────────────────────────────────────
      # Deployed to ~/.face so that any greeter that respects the
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

      services = {
        network-manager-applet.enable = true;
      };
    });

    services = {
      # ── Keyring ──────────────────────────────────────────────────────────────
      gnome.gnome-keyring.enable = true;

      # ── Virtual filesystem / trash / network mounts ────────────────────────
      gvfs.enable = true;

      # ── Power state information ───────────────────────────────────────────────
      upower.enable = true;
    };

    # ── dconf ──────────────────────────────────────────────────────────────────
    programs.dconf.enable = true;

    # ── GSettings ────────────────────────────────────────────────────────────
    environment.systemPackages = with pkgs; [
      glib
      gsettings-desktop-schemas
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
  };
}
