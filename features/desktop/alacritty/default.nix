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
  cfg = config.desktop.alacritty;

  # Pull from the shared terminal module
  t = config.terminal;

  inherit (pkgs.stdenv) isDarwin;
in
{
  options.desktop.alacritty = {
    enable = lib.mkEnableOption "Enable Alacritty terminal emulator";
  };

  imports = [ ../../../modules/terminal/common.nix ];

  config = lib.mkIf cfg.enable {
    home-manager.users = lib.genAttrs allUsers (_: {
      home.packages = [ pkgs.alacritty ];

      programs.alacritty = {
        enable = true;

        # TOML config generated via Nix → TOML
        settings = {
          env.TERM = "xterm-256color";

          window = {
            padding = {
              x = 10;
              y = 10;
            };

            decorations = "Buttonless";

            # opacity from shared module
            inherit (t) opacity;

            blur = true;

            option_as_alt = lib.mkIf isDarwin "Both";
          };

          font = {
            # shared font family and size
            normal.family = t.font.family;
            inherit (t.font) size;
          };
        };
      };

      # Catppuccin still allowed to inject its theme overrides
      catppuccin.alacritty.enable = true;
    });
  };
}
