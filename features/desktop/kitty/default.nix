{
  lib,
  pkgs,
  config,
  user,
  extraUsers ? [ ],
  ...
}:

let
  allUsers = [ user ] ++ extraUsers;
  cfg = config.desktop.kitty;

  # Pull from the shared terminal module
  t = config.terminal;

  inherit (pkgs.stdenv) isDarwin;
in
{
  options.desktop.kitty = {
    enable = lib.mkEnableOption "Kitty terminal emulator";
  };

  imports = [ ../../../modules/terminal/common.nix ];

  config = lib.mkIf cfg.enable {
    home-manager.users = lib.genAttrs allUsers (_: {
      programs.kitty = {
        enable = true;

        # Shared font family and size (top-level HM font option).
        font = {
          name = t.font.family;
          inherit (t.font) size;
        };

        # kitty.conf is a flat key/value config, unlike alacritty's nested
        # TOML. Translate the shared settings accordingly.
        settings = {
          # window.padding.{x,y} = 10 -> single padding width.
          window_padding_width = 10;

          # alacritty "Buttonless" decorations -> hide the buttons but keep
          # the title bar drag area on macOS.
          hide_window_decorations = "titlebar-only";

          # opacity from shared module (alacritty window.opacity).
          background_opacity = t.opacity;

          # window.blur = true.
          background_blur = 1;
        }
        // lib.optionalAttrs isDarwin {
          # option_as_alt = "Both".
          macos_option_as_alt = "both";
        };
      };

      # Catppuccin still allowed to inject its theme overrides
      catppuccin.kitty.enable = true;
    });
  };
}
