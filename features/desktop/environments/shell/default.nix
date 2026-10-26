{
  lib,
  ...
}:
{
  # The desktop shell (bar, notifications, OSD, wallpaper, session menu) is
  # selected per host. Each shell module sets `startupUnits`,
  # `startupCommands` and `commands` when it is the active provider, and the
  # compositor modules (../hyprland, ../niri) consume them, so the
  # compositors never hard-code a particular shell.
  options.desktop.environments.shell = {
    provider = lib.mkOption {
      type = lib.types.enum [
        "wayle"
        "noctalia"
      ];
      default = "wayle";
      description = ''
        Desktop shell used by the Hyprland and niri sessions. `wayle` is the
        hand-assembled stack (wayle plus hypridle, hyprsunset, polkit-gnome
        and cliphist); `noctalia` replaces all of those with Noctalia.
      '';
    };

    startupUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "systemd user units the compositor restarts at session start for the selected shell.";
    };

    startupCommands = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Shell commands the compositor runs once at session start for the selected shell.";
    };

    commands = lib.mkOption {
      description = "Commands the compositor keybinds call; each shell provides its own implementation.";
      type = lib.types.submodule {
        options = {
          volumeUp = lib.mkOption {
            type = lib.types.str;
            description = "Raise the default output volume by 5%.";
          };
          volumeDown = lib.mkOption {
            type = lib.types.str;
            description = "Lower the default output volume by 5%.";
          };
          volumeMute = lib.mkOption {
            type = lib.types.str;
            description = "Toggle mute on the default output.";
          };
          micMute = lib.mkOption {
            type = lib.types.str;
            description = "Toggle mute on the default input.";
          };
          idleInhibitToggle = lib.mkOption {
            type = lib.types.str;
            description = "Toggle an indefinite idle inhibitor.";
          };
        };
      };
    };
  };
}
