{
  lib,
  config,
  user,
  extraUsers ? [ ],
  isLaptop ? false,
  wayleMonitor ? null,
  ...
}:
let
  allUsers = [ user ] ++ extraUsers;
  cfg = config.desktop.environments.modules.wayle;
  shell = config.desktop.environments.shell;

  # Symbolic state icons for the custom module, shipped in-tree and installed
  # into wayle's custom-icon directory (~/.local/share/wayle/icons) so the
  # icon-map names always resolve without depending on `wayle icons setup`
  # reaching a CDN. The `cm-` prefix is wayle's convention for user-supplied
  # ("custom module") icons. Rendering the glyph through the icon slot (rather
  # than as a text label) lets GTK size it as an icon, which is visibly larger
  # than the Nerd Font label was.
  nixosStateIcons = {
    reboot = ./icons/cm-nixos-state-reboot-symbolic.svg;
    update = ./icons/cm-nixos-state-update-symbolic.svg;
    clean = ./icons/cm-nixos-state-clean-symbolic.svg;
  };

  # User stylesheet (wayle's custom-styles escape hatch). Provides the
  # state-driven colouring for the nixos-state pill. See the file header and
  # the `class = "nixos-state-pill"` instance class in the bar layout below.
  wayleUserStyles = ./styles/index.scss;

  # Catppuccin Mocha palette with the Mauve accent as `primary`, matching
  # the repo-wide catppuccin default (flavor = mocha, accent = mauve).
  # Not yet an upstream wayle built-in theme; shipped inline so the config is
  # fully declarative. A separate PR adds the flavors to wayle-rs/wayle.
  catppuccinMochaPalette = {
    bg = "#1e1e2e"; # base
    surface = "#181825"; # mantle
    elevated = "#313244"; # surface0
    fg = "#cdd6f4"; # text
    fg-muted = "#a6adc8"; # subtext0
    primary = "#cba6f7"; # mauve (accent)
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
      default = "/home/${user}/Pictures/Background-flat";
      description = ''
        Directory the wayle wallpaper engine cycles through. Populated by the
        catppuccin-wallpapers derivation, symlinked in
        features/desktop/environments/default.nix.

        This MUST be the flat mirror (Background-flat), not the browsable
        Background tree: wayle's cycler scans its cycling-directory
        non-recursively (fs::read_dir), so a directory of subdirectories
        yields zero wallpapers and cycling silently does nothing.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    desktop.environments.shell = {
      startupUnits = [ "wayle" ];
      commands = {
        volumeUp = "wayle audio output-volume +5";
        volumeDown = "wayle audio output-volume -5";
        volumeMute = "wayle audio output-mute";
        micMute = "wayle audio input-mute";
        idleInhibitToggle = "wayle idle toggle --indefinite";
      };
    };

    home-manager.users = lib.genAttrs allUsers (_: {
      # Install the in-tree symbolic state icons into wayle's custom-icon
      # directory so the custom module's icon-map references resolve.
      xdg.dataFile = {
        "wayle/icons/cm-nixos-state-reboot-symbolic.svg".source = nixosStateIcons.reboot;
        "wayle/icons/cm-nixos-state-update-symbolic.svg".source = nixosStateIcons.update;
        "wayle/icons/cm-nixos-state-clean-symbolic.svg".source = nixosStateIcons.clean;
      };

      # Layer the user stylesheet on top of wayle's built-in styles for the
      # state-driven pill colouring. `force` because wayle writes a starter
      # `styles/index.scss` (with a comment) the first time it runs, which
      # would otherwise block home-manager activation as an unmanaged file.
      xdg.configFile."wayle/styles/index.scss" = {
        source = wayleUserStyles;
        force = true;
      };

      services.wayle = {
        enable = true;

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
          # ~/Pictures/Background-flat directory, advance every 5 minutes.
          # The flat directory is required: wayle's cycler reads its
          # cycling-directory non-recursively, so the nested Background tree
          # would yield zero images.
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
          # wayle isn't focus-aware, so on multi-monitor hosts the OSD would
          # otherwise default to wayle's own "primary" output regardless of
          # which monitor the user is actually looking at. `wayleMonitor`
          # (set per-host in flake/hosts/nixos.nix, e.g. "DP-3" on maranello)
          # pins it to a fixed connector instead.
          osd = {
            enabled = true;
            position = "top";
          }
          // lib.optionalAttrs (wayleMonitor != null) { monitor = wayleMonitor; };

          # ── Bar layout (mirrors fredbar) ────────────────────────────────
          # Left: dashboard button (distro icon → lock/logout/reboot/power
          #       dropdown, replacing the separate power module) plus the
          #       system-tray app indicators.
          # Center: workspace indicator + focused window title.
          # Right: media, then the status cluster (volume, network, battery,
          #        clock), the idle-inhibit indicator, and the notification
          #        centre. The battery module is only added on laptop
          #        chassis (isLaptop); wayle has no "hide when absent"
          #        option and renders a permanent alert glyph for a missing
          #        battery, and battery presence cannot be auto-detected at
          #        flake-eval time (eval runs on the builder, not the
          #        target), so it is gated on the host's form-factor signal.
          bar = {
            location = "top";
            background-opacity = 50;
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
                ]
                ++ lib.optional isLaptop "battery"
                ++ [
                  "idle-inhibit"
                  # Classed instance: the unique `nixos-state-pill` class lets
                  # the per-state SCSS rules (styles/index.scss) scope their
                  # colour overrides to *this* module only. The state classes
                  # the script emits (reboot/updates/clean) are never styled on
                  # their own, so they cannot bleed into other pills (notably
                  # wayle's built-in `updates` module).
                  {
                    module = "custom-nixos-state";
                    class = "nixos-state-pill";
                  }
                  "clock"
                  "notifications"
                ];
              }
            ];
          };

          modules = {
            # ── Dashboard dropdown (lock / logout / reboot / poweroff) ────
            # wayle's dropdown actions are static shell commands. Point the
            # session actions at the compositor-aware dispatch scripts so
            # logout/reboot/poweroff do the right thing under both Hyprland
            # (graceful hyprshutdown) and niri (niri msg action quit /
            # systemctl). Lock stays the generic loginctl call, which works
            # everywhere. See ../../shell/session-actions.nix.
            dashboard = {
              dropdown-lock-command = "loginctl lock-session";
              dropdown-logout-command = lib.getExe shell.sessionActions.logout;
              dropdown-reboot-command = lib.getExe shell.sessionActions.reboot;
              dropdown-poweroff-command = lib.getExe shell.sessionActions.poweroff;
            };

            # ── Clock (24h with seconds, matching fredbar) ────────────────
            clock = {
              format = "%H:%M:%S";
            };

            weather = {
              location = "Albuquerque";
            };

            idle-inhibit = {
              label-show = false;
            };

            network = {
              label-show = false;
            };

            volume = {
              label-show = false;
            };

            window-title = {
              label-max-length = 20;
              icon-mappings = {
                "freminal" = "freminal";
                "frext" = "frext";
              };
            };

            media = {
              label-show = false;
            };

            # ── NixOS config state (ports fred-bar's updates module) ──────
            # Polls ../../shell/nixos-deploy-state.nix every 60s. It emits JSON with an
            # `alt` field (reboot|update|clean) that selects the icon via
            # icon-map, a `tooltip` for hover, and a `class` carried for future
            # custom CSS. The icon renders in the icon slot (sized like a real
            # icon, larger than a label glyph); the text label is hidden. The
            # pill is Catppuccin Mocha Peach with a dark base-coloured icon for
            # contrast.
            custom = [
              {
                id = "nixos-state";
                command = lib.getExe shell.nixosDeployState;
                mode = "poll";
                interval-ms = 60000;
                icon-show = true;
                label-show = false;
                tooltip-format = "{{ tooltip }}";
                icon-map = {
                  reboot = "cm-nixos-state-reboot-symbolic";
                  update = "cm-nixos-state-update-symbolic";
                  clean = "cm-nixos-state-clean-symbolic";
                };
                # The bar's button-variant is "block-prefix", so the icon
                # lives in a coloured pill container driven by icon-bg-color
                # (NOT button-bg-color, which is the outer button that blends
                # into the edge). This static peach is a FALLBACK: the per-state
                # colouring is done dynamically in styles/index.scss (red /
                # peach / green by state). The dark base icon foreground keeps
                # contrast against all three state colours.
                icon-color = catppuccinMochaPalette.bg; # #1e1e2e base
                # icon-bg-color = "#fab387"; # fallback pill colour (peach)
                # button-bg-color = "#fab387"; # fallback outer button
              }
            ];

            # ── Notification centre + popups ──────────────────────────────
            # Bar icon shows unread count; left-click opens history, right
            # click toggles DND. Popups anchor top-right. Like the OSD above,
            # wayle isn't focus-aware, so `wayleMonitor` pins popups to a
            # fixed connector on multi-monitor hosts instead of relying on
            # wayle's default "primary" output.
            notifications = {
              popup-position = "top-right";
              popup-margin-x = 8.0;
              popup-margin-y = 8.0;
            }
            // lib.optionalAttrs (wayleMonitor != null) { popup-monitor = wayleMonitor; };
          };
        };
      };
    });
  };
}
