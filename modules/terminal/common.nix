{
  lib,
  pkgs,
  ...
}:

let
  inherit (pkgs.stdenv.hostPlatform) isDarwin;
in

{
  options.terminal = {
    font.family = lib.mkOption {
      type = lib.types.str;
      default = if isDarwin then "CaskaydiaCove Nerd Font" else "Caskaydia Cove Nerd Font";
      description = "Default terminal font";
    };

    font.size = lib.mkOption {
      type = lib.types.number;
      default = 12;
      description = "Default terminal font size, in points.";
    };

    opacity = lib.mkOption {
      type = lib.types.float;
      default = 0.95;
      description = "Background opacity for terminal emulators that support it, from 0.0 (fully transparent) to 1.0 (opaque).";
    };

    theme = lib.mkOption {
      type = lib.types.str;
      default = "Catppuccin Mocha";
      description = "Colour scheme name shared across terminal emulators that support named Catppuccin themes.";
    };

    enableWayland = lib.mkOption {
      type = lib.types.bool;
      default = !isDarwin;
      description = "Whether terminal emulators should prefer their native Wayland backend instead of XWayland. Defaults to off on Darwin, where Wayland does not apply.";
    };

    # Terminal-specific overrides
    wezterm.extraLua = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Extra Lua snippet appended to the generated WezTerm config, for settings not covered by the shared terminal options.";
    };

    alacritty.extraSettings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Extra settings merged into the generated Alacritty TOML config, for options not covered by the shared terminal options.";
    };
  };
}
