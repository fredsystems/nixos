{
  lib,
  ...
}:
{
  # The desktop shell (bar, notifications, OSD, wallpaper, session menu) sets
  # `startupUnits`, `startupCommands` and `commands`, and the compositor
  # modules (../hyprland, ../niri) consume them, so the compositors never
  # hard-code the shell. Noctalia (../modules/noctalia) is the only shell.
  imports = [
    ./nixos-deploy-state.nix
    ./session-actions.nix
  ];

  options.desktop.environments.shell = {
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
