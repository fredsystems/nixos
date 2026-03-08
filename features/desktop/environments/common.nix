{
  lib,
  config,
  pkgs,
  user,
  extraUsers ? [ ],
  ...
}:
with lib;
let
  allUsers = [ user ] ++ extraUsers;
  cfg = config.desktop.environments.common;
in
{
  options.desktop.environments.common = {
    enable = mkOption {
      description = "Enable shared Wayland compositor infrastructure (keyring, gvfs, polkit, portal, etc.)";
      default = false;
    };
  };

  config = mkIf cfg.enable {
    home-manager.users = lib.genAttrs allUsers (_: {
      gtk = {
        enable = true;
        gtk3.extraConfig = {
          gtk-application-prefer-dark-theme = 1;
        };
        gtk4.extraConfig = {
          gtk-application-prefer-dark-theme = 1;
        };
        theme = {
          name = "Catppuccin-GTK-Mauve-Dark";
          package = pkgs.magnetic-catppuccin-gtk.override {
            accent = [ "mauve" ];
            shade = "dark";
          };
        };
      };
    });

    services = {
      # ── Keyring ──────────────────────────────────────────────────────────────
      # Provides the D-Bus secret service (org.freedesktop.secrets), auto-unlocks
      # at login via PAM, and exposes the PKCS#11 / SSH agent sockets.
      # Required by: 1Password, Thunderbird, anything that stores credentials.
      gnome.gnome-keyring.enable = true;

      # ── Virtual filesystem / trash / network mounts ────────────────────────
      # Required by Nautilus for MTP, SMB, SFTP, and the desktop trash integration
      # that udiskie also relies on.
      gvfs.enable = true;

      # ── Power state information ───────────────────────────────────────────────
      # Provides battery / AC status over D-Bus (UPower). Needed by status bars
      # (fredbar), notification daemons, and swayidle rules.
      # mkForce resolves the priority conflict introduced by disabling GNOME DE
      # (gnome.nix derives this from powerManagement.enable = false) while
      # cosmic.nix hardcodes true.
      upower.enable = lib.mkForce true;
    };

    # ── dconf ──────────────────────────────────────────────────────────────────
    # Backend for gsettings. Both Hyprland and Niri call:
    #   gsettings set org.gnome.desktop.interface color-scheme / gtk-theme
    # at startup for GTK dark mode and theme application. Without dconf enabled
    # at the NixOS level the gsettings writes are silently discarded.
    programs.dconf.enable = true;

    # ── Polkit authentication agent ────────────────────────────────────────────
    # polkit-gnome provides the graphical "enter password" dialog that pops up
    # when a privileged action is requested (e.g. mounting, package installs).
    # The package is installed here so it is available system-wide; the actual
    # user service that starts the agent is defined below so it auto-restarts.
    environment.systemPackages = with pkgs; [
      polkit_gnome # polkit-gnome-authentication-agent-1 binary
      glib # gsettings binary — needed for GTK theming execs at startup
      gsettings-desktop-schemas # org.gnome.desktop.interface schemas (color-scheme, gtk-theme, etc.)
    ];

    # Point gsettings at the compiled schema dir inside the package.
    # Without GNOME DE nothing sets up XDG_DATA_DIRS to include the
    # gsettings-desktop-schemas store path, so gsettings calls at
    # compositor startup (color-scheme, gtk-theme) find no schemas.
    environment.sessionVariables.GSETTINGS_SCHEMA_DIR = "${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}/glib-2.0/schemas";

    # ── XDG desktop portals ────────────────────────────────────────────────────
    # xdg-desktop-portal-gtk covers file chooser, screenshots, and appearance
    # portals for both Hyprland and Niri. Each compositor adds its own
    # portal backend on top of this in its own module.
    xdg.portal = {
      enable = true;
      extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
      config.common.default = "*";
    };

    # ── Nautilus file manager ──────────────────────────────────────────────────
    # Installed independently of the GNOME DE. Niri binds Mod+A to "nautilus".
    # nautilus-open-any-terminal patches the right-click "Open Terminal" action.
    programs.nautilus-open-any-terminal = {
      enable = true;
      terminal = "wezterm";
    };

    # ── Shared user packages ───────────────────────────────────────────────────
    # Packages used in both Hyprland and Niri. Compositor-specific packages
    # (e.g. hyprland/niri binaries themselves) stay in their own modules.
    users.users = lib.genAttrs allUsers (_: {
      packages = with pkgs; [
        # File manager + supporting libraries
        nautilus
        gvfs
        gnome.gvfs

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
        swayidle
        swaylock

        # Media controls (playerctl keybinds shared across both compositors)
        playerctl

        # Notification daemon
        swaynotificationcenter

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
        swaybg

        # Misc Wayland utilities
        wev

        # xdg-open — needed by udiskie for file manager integration and
        # generally required by any app that opens URLs/files via xdg-open
        xdg-utils
      ];
    });

    # ── Polkit agent user service ──────────────────────────────────────────────
    # Runs polkit-gnome-authentication-agent-1 as a persistent user service.
    # Both Hyprland (exec-once) and Niri (spawn-at-startup) restart this unit
    # at compositor startup to ensure it is bound to the correct Wayland session.
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
