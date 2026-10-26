{
  lib,
  config,
  pkgs,
  ...
}:
let
  # ── Compositor-aware session actions ──────────────────────────────────────
  # The shells' session menus run static shell commands, but a correct
  # logout/reboot/poweroff differs by compositor:
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
  # $HYPRLAND_INSTANCE_SIGNATURE when Hyprland is up) so the same shell config
  # works on both. hyprshutdown is referenced by bare name (it is installed by
  # the hyprland module and only present in a Hyprland session); niri is
  # pinned to its store path.
  #
  # hyprshutdown MUST be launched detached from the shell's process tree. The
  # shell's bar is a layer-shell surface, so hyprshutdown's "close every app"
  # pass SIGTERMs the shell's own PID. If hyprshutdown is a descendant of the
  # shell (it is, when the shell spawns the menu command via `sh -c`), killing
  # the shell tears hyprshutdown down with it -- before its GUI renders or it
  # issues `/dispatch exit`. The symptom is exactly "apps close but the
  # compositor just sits there, and running hyprshutdown by hand works" (a
  # hand-launched hyprshutdown is not a shell descendant).
  # `systemd-run --user --scope` runs hyprshutdown in its own transient scope,
  # fully decoupled from the shell's process tree and signal propagation, so
  # it survives the shell being killed and runs to completion (GUI, Hyprland
  # exit, and --post-cmd).
  #
  # Use the same niri package the system actually installs
  # (config.programs.niri.package, from niri.nixosModules.niri) rather than
  # nixpkgs' own `pkgs.niri`. They're different derivations; referencing
  # nixpkgs' `pkgs.niri` here forced an extra, entirely separate niri build.
  niriBin = lib.getExe config.programs.niri.package;
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
in
{
  options.desktop.environments.shell.sessionActions = {
    logout = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = "Compositor-aware graceful logout command for shell session menus.";
      default = pkgs.writeShellApplication {
        name = "session-logout";
        # hyprshutdown is intentionally not in runtimeInputs: it is a Hyprland-
        # only tool installed by the hyprland module and resolved from PATH only
        # inside a Hyprland session.
        text = ''
          ${detectCompositor}
          case "$(detect_compositor)" in
            hyprland) exec ${systemdRun} --user --scope --quiet hyprshutdown --no-fork ;;
            niri)     exec ${niriBin} msg action quit ;;
            *)        echo "session-logout: unknown compositor" >&2; exit 1 ;;
          esac
        '';
      };
    };

    reboot = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = "Compositor-aware graceful reboot command for shell session menus.";
      default = pkgs.writeShellApplication {
        name = "session-reboot";
        text = ''
          ${detectCompositor}
          case "$(detect_compositor)" in
            hyprland) exec ${systemdRun} --user --scope --quiet hyprshutdown --no-fork -t 'Restarting…' --post-cmd 'systemctl reboot' ;;
            niri)     exec systemctl reboot ;;
            *)        exec systemctl reboot ;;
          esac
        '';
      };
    };

    poweroff = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = "Compositor-aware graceful poweroff command for shell session menus.";
      default = pkgs.writeShellApplication {
        name = "session-poweroff";
        text = ''
          ${detectCompositor}
          case "$(detect_compositor)" in
            hyprland) exec ${systemdRun} --user --scope --quiet hyprshutdown --no-fork -t 'Shutting down…' --post-cmd 'systemctl poweroff' ;;
            niri)     exec systemctl poweroff ;;
            *)        exec systemctl poweroff ;;
          esac
        '';
      };
    };
  };
}
