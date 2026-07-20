{
  lib,
  config,
  pkgs,
  user,
  extraUsers ? [ ],
  isLaptop ? false,
  wayleMonitor ? null,
  ...
}:
let
  allUsers = [ user ] ++ extraUsers;
  cfg = config.desktop.environments.modules.wayle;

  # ── Compositor-aware session actions for the dashboard dropdown ─────────
  # wayle is compositor-agnostic and its dashboard dropdown runs static
  # shell commands (`sh -c`). But a correct logout/reboot/poweroff differs by
  # compositor:
  #
  #   * Hyprland: use `hyprshutdown`, which gracefully asks every app to
  #     close (and waits) before quitting the compositor, rather than letting
  #     apps die when Hyprland exits. For reboot/poweroff it runs the
  #     `systemctl` command via `--post-cmd` *after* the graceful exit, so the
  #     machine only reboots once apps have cleanly shut down.
  #   * Niri: `niri msg action quit` cleanly exits the session (and shows
  #     niri's own confirmation dialog). Reboot/poweroff just call `systemctl`
  #     directly; the session teardown closes apps.
  #
  # Each action is a single dispatch script that detects the running
  # compositor at runtime ($NIRI_SOCKET when niri is up,
  # $HYPRLAND_INSTANCE_SIGNATURE when Hyprland is up) so the same wayle config
  # works on both. hyprshutdown is referenced by bare name (it is installed by
  # the hyprland module and only present in a Hyprland session); niri is
  # pinned to its store path.
  #
  # hyprshutdown MUST be launched detached from wayle's process tree. wayle's
  # bar is a layer-shell surface, so hyprshutdown's "close every app" pass
  # SIGTERMs wayle's own PID. If hyprshutdown is a descendant of wayle (it is,
  # when wayle spawns the dropdown command via `sh -c`), killing wayle tears
  # hyprshutdown down with it — before its GUI renders or it issues
  # `/dispatch exit`. The symptom is exactly "apps close but the compositor
  # just sits there, and running hyprshutdown by hand works" (a hand-launched
  # hyprshutdown is not a wayle descendant). `systemd-run --user --scope` runs
  # hyprshutdown in its own transient scope, fully decoupled from wayle's
  # process tree and signal propagation, so it survives wayle being killed and
  # runs to completion (GUI, Hyprland exit, and --post-cmd).
  niriBin = lib.getExe pkgs.niri;
  systemdRun = "${pkgs.systemd}/bin/systemd-run";
  detectCompositor = ''
    # Returns: prints "hyprland", "niri", or "unknown".
    detect_compositor() {
      if [ -n "''${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
        echo hyprland
      elif [ -n "''${NIRI_SOCKET:-}" ]; then
        echo niri
      else
        case "''${XDG_CURRENT_DESKTOP:-}" in
          *Hyprland*) echo hyprland ;;
          *niri*) echo niri ;;
          *) echo unknown ;;
        esac
      fi
    }
  '';

  sessionLogout = pkgs.writeShellApplication {
    name = "wayle-session-logout";
    # hyprshutdown is intentionally not in runtimeInputs: it is a Hyprland-
    # only tool installed by the hyprland module and resolved from PATH only
    # inside a Hyprland session.
    text = ''
      ${detectCompositor}
      case "$(detect_compositor)" in
        hyprland) exec ${systemdRun} --user --scope --quiet hyprshutdown --no-fork ;;
        niri)     exec ${niriBin} msg action quit ;;
        *)        echo "wayle-session-logout: unknown compositor" >&2; exit 1 ;;
      esac
    '';
  };

  sessionReboot = pkgs.writeShellApplication {
    name = "wayle-session-reboot";
    text = ''
      ${detectCompositor}
      case "$(detect_compositor)" in
        hyprland) exec ${systemdRun} --user --scope --quiet hyprshutdown --no-fork -t 'Restarting…' --post-cmd 'systemctl reboot' ;;
        niri)     exec systemctl reboot ;;
        *)        exec systemctl reboot ;;
      esac
    '';
  };

  sessionPoweroff = pkgs.writeShellApplication {
    name = "wayle-session-poweroff";
    text = ''
      ${detectCompositor}
      case "$(detect_compositor)" in
        hyprland) exec ${systemdRun} --user --scope --quiet hyprshutdown --no-fork -t 'Shutting down…' --post-cmd 'systemctl poweroff' ;;
        niri)     exec systemctl poweroff ;;
        *)        exec systemctl poweroff ;;
      esac
    '';
  };

  # ── NixOS config state indicator (ports fred-bar's waybar-updates.sh) ──
  # Reports, in priority order: a pending reboot (/run/reboot-required), a
  # checked-out branch other than main, or how many commits the local config
  # is behind its upstream. Emits wayle-custom-module JSON ({text,class,
  # tooltip}); the `class` is carried for when wayle ships custom CSS, while
  # the Nerd Font glyph conveys state today.
  #
  # The network `git fetch` is throttled to at most once per hour via a
  # timestamp stamp file, so the wayle display poll (every 60s) only ever
  # reads cheap local git state and never blocks on the network.
  nixosStateRepo = "/home/${user}/GitHub/nixos";
  nixosStateScript = pkgs.writeShellApplication {
    name = "wayle-nixos-state";
    runtimeInputs = [
      pkgs.git
      pkgs.coreutils
    ];
    text = ''
      repo="''${NIXOS_REPO:-${nixosStateRepo}}"
      main_branch="''${MAIN_BRANCH:-main}"
      fetch_max_age=3600 # seconds (1 hour)

      # The module renders the icon via the icon slot: the JSON `alt` field
      # keys into the custom module's icon-map (reboot|update|clean), and the
      # `class` is carried for future custom CSS. `text` is left empty because
      # label-show is off; the human-readable state lives in `tooltip`.
      emit() {
        # $1 = alt (icon-map key), $2 = class, $3 = tooltip
        printf '{"text":"","alt":"%s","class":"%s","tooltip":"%s"}\n' "$1" "$2" "$3"
      }

      # 1. Reboot required (highest priority).
      if [ -f /run/reboot-required ]; then
        emit "reboot" "reboot" "Reboot required"
        exit 0
      fi

      # 2. Must be a git repository to say anything further. Styled as the
      #    neutral "clean" state (non-actionable) but with its own tooltip.
      if [ ! -d "$repo/.git" ]; then
        emit "clean" "clean" "NixOS config is not a git repository"
        exit 0
      fi
      cd "$repo"

      # 3. Non-main branch is treated as "dirty".
      current_branch="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
      if [ -n "$current_branch" ] && [ "$current_branch" != "$main_branch" ]; then
        emit "update" "updates" "On non-main branch: $current_branch"
        exit 0
      fi

      # 4. Resolve upstream tracking ref.
      upstream="$(git for-each-ref --format='%(upstream:short)' \
        "$(git symbolic-ref -q HEAD)" 2>/dev/null || true)"
      if [ -z "$upstream" ]; then
        emit "update" "updates" "No upstream configured for $main_branch"
        exit 0
      fi

      # 5. Throttled network fetch: only fetch if the stamp is older than
      #    fetch_max_age (or missing). Failures are non-fatal.
      stamp="''${XDG_RUNTIME_DIR:-/tmp}/wayle-nixos-state.fetch"
      now="$(date +%s)"
      last=0
      if [ -f "$stamp" ]; then
        last="$(cat "$stamp" 2>/dev/null || echo 0)"
      fi
      if [ "$((now - last))" -ge "$fetch_max_age" ]; then
        if git fetch --quiet 2>/dev/null; then
          echo "$now" > "$stamp"
        fi
      fi

      # 6. Count commits behind upstream (local state only, no network).
      behind="$(git rev-list --count "HEAD..$upstream" 2>/dev/null || echo 0)"
      if [ "$behind" -gt 0 ]; then
        if [ "$behind" -eq 1 ]; then
          emit "update" "updates" "Config behind upstream by 1 commit"
        else
          emit "update" "updates" "Config behind upstream by $behind commits"
        fi
        exit 0
      fi

      # 7. Clean and up to date.
      emit "clean" "clean" "System configuration up to date"
    '';
  };

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
            # everywhere. See the script definitions in the `let` block.
            dashboard = {
              dropdown-lock-command = "loginctl lock-session";
              dropdown-logout-command = lib.getExe sessionLogout;
              dropdown-reboot-command = lib.getExe sessionReboot;
              dropdown-poweroff-command = lib.getExe sessionPoweroff;
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
            # Polls the local script every 60s; the script self-throttles
            # its network fetch to once an hour. The script emits JSON with an
            # `alt` field (reboot|update|clean) that selects the icon via
            # icon-map, a `tooltip` for hover, and a `class` carried for future
            # custom CSS. The icon renders in the icon slot (sized like a real
            # icon, larger than a label glyph); the text label is hidden. The
            # pill is Catppuccin Mocha Peach with a dark base-coloured icon for
            # contrast.
            custom = [
              {
                id = "nixos-state";
                command = lib.getExe nixosStateScript;
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
