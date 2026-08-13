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
    };

    opacity = lib.mkOption {
      type = lib.types.float;
      default = 0.95;
    };

    theme = lib.mkOption {
      type = lib.types.str;
      default = "Catppuccin Mocha";
    };

    enableWayland = lib.mkOption {
      type = lib.types.bool;
      default = !isDarwin;
    };

    # Terminal-specific overrides
    wezterm.extraLua = lib.mkOption {
      type = lib.types.lines;
      default = "";
    };

    alacritty.extraSettings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
    };
  };
}
