{
  lib,
  config,
  pkgs,
  user,
  extraUsers ? [ ],
  inputs,
  ...
}:
let
  allUsers = [ user ] ++ extraUsers;
  cfg = config.desktop.environments.modules.wayle;

  # Wayle 0.6.0 lives in nixpkgs-stable (26.05); the unstable nixpkgs this
  # desktop otherwise tracks is still on 0.4.1, whose config schema differs.
  # The services.wayle home-manager module is byte-for-byte identical between
  # the unstable and stable home-manager inputs, so we keep the active
  # (unstable) module and only override the package to the 0.6.0 build.
  #
  # TODO(wayle-unstable): This pulls wayle from nixpkgs-stable purely as a
  # bridge until nixpkgs-unstable advances to >= 0.6.0 (NixOS PR #526419
  # landed in 26.05 but has not yet reached the unstable channel this flake
  # pins). Once unstable carries 0.6.0+, drop this override and let wayle come
  # from the desktop's normal `pkgs`. Deliberately NOT recategorizing
  # nixpkgs-stable from `server` -> `global` in CI for this temporary window;
  # the override is expected to be removed on the next unstable bump.
  waylePackage = inputs.nixpkgs-stable.legacyPackages.${pkgs.stdenv.hostPlatform.system}.wayle;

  # Catppuccin Mocha palette with the Lavender accent as `primary`, matching
  # the repo-wide catppuccin default (flavor = mocha, accent = lavender).
  # Not yet an upstream wayle built-in theme; shipped inline so the config is
  # fully declarative. A separate PR adds the flavors to wayle-rs/wayle.
  catppuccinMochaPalette = {
    bg = "#1e1e2e"; # base
    surface = "#181825"; # mantle
    elevated = "#313244"; # surface0
    fg = "#cdd6f4"; # text
    fg-muted = "#a6adc8"; # subtext0
    primary = "#b4befe"; # lavender (accent)
    red = "#f38ba8";
    yellow = "#f9e2af";
    green = "#a6e3a1";
    blue = "#89b4fa";
  };
in
{
  options.desktop.environments.modules.wayle = {
    enable = lib.mkEnableOption "wayle desktop shell (bar, OSD, notifications, wallpaper)";

    wallpaperDirectory = lib.mkOption {
      type = lib.types.str;
      default = "/home/${user}/Pictures/Background";
      description = ''
        Directory the wayle wallpaper engine cycles through. Populated by the
        catppuccin-wallpapers derivation, symlinked in
        features/desktop/environments/default.nix.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home-manager.users = lib.genAttrs allUsers (_: {
      services.wayle = {
        enable = true;
        package = waylePackage;

        settings = {
          # ── Shell-wide fonts ────────────────────────────────────────────
          # Match the rest of the desktop (features/desktop/fonts): SF Pro
          # Display Nerd Font for UI text, Caskaydia Cove Nerd Font for mono.
          general = {
            font-sans = "SFProDisplay Nerd Font";
            font-mono = "Caskaydia Cove Nerd Font";
          };

          # ── Shell-wide styling ──────────────────────────────────────────
          styling = {
            theme-provider = "wayle";
            rounding = "sm";
            palette = catppuccinMochaPalette;
          };

          # ── Wallpaper engine (replaces hyprpaper) ───────────────────────
          # engine-enabled = true pulls in services.awww (the swww-derived
          # backend) automatically via the home-manager module. Cycling
          # mirrors the previous hyprpaper behaviour: shuffle the
          # ~/Pictures/Background tree, advance every 5 minutes.
          wallpaper = {
            engine-enabled = true;
            cycling-enabled = true;
            cycling-directory = cfg.wallpaperDirectory;
            cycling-mode = "shuffle";
            cycling-interval-mins = 5;
            transition-type = "simple";
            transition-duration = 0.7;
            transition-fps = 60;
          };

          # ── On-screen display (replaces volume.sh / kbbacklight OSD) ─────
          osd = {
            enabled = true;
          };

          # ── Bar layout (mirrors fredbar) ────────────────────────────────
          # Left: dashboard button (distro icon → lock/logout/reboot/power
          #       dropdown, replacing the separate power module) plus the
          #       system-tray app indicators.
          # Center: workspace indicator + focused window title.
          # Right: media, then the status cluster (volume, network, battery,
          #        clock), the idle-inhibit indicator, and the notification
          #        centre.
          bar = {
            location = "top";
            background-opacity = 80;
            layout = [
              {
                monitor = "*";
                left = [
                  "dashboard"
                  "weather"
                  "systray"
                ];
                center = [
                  "hyprland-workspaces"
                  "niri-workspaces"
                  "window-title"
                ];
                right = [
                  "media"
                  "volume"
                  "network"
                  "battery"
                  "idle-inhibit"
                  "clock"
                  "notifications"
                ];
              }
            ];
          };

          modules = {
            # ── Clock (24h with seconds, matching fredbar) ────────────────
            clock = {
              format = "%H:%M:%S";
            };

            weather = {
              location = "Albuquerque";
            };

            # ── Notification centre + popups ──────────────────────────────
            # Bar icon shows unread count; left-click opens history, right
            # click toggles DND. Popups anchor top-right (single-monitor
            # desktops use the default "primary" popup-monitor).
            notifications = {
              popup-position = "top-right";
              popup-margin-x = 8.0;
              popup-margin-y = 8.0;
            };
          };
        };
      };
    });
  };
}
