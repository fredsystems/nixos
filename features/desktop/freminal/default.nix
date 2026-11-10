{
  lib,
  config,
  inputs,
  system,
  ...
}:
let
  cfg = config.desktop.freminal;
  t = config.terminal;
  allUsers = config.shared.allUsers;

  freminalPackage = inputs.freminal.packages.${system}.freminal;
in
{
  imports = [ ../../../modules/terminal/common.nix ];

  options.desktop.freminal = {
    enable = lib.mkEnableOption "freminal terminal emulator";
  };

  config = lib.mkIf cfg.enable {
    home-manager.users = lib.genAttrs allUsers (_: {
      programs.freminal = {
        enable = true;
        package = freminalPackage;
        settings = {
          font = {
            inherit (t.font) family;
            size = t.font.size * 1.0;
          };
          theme = {
            mode = "dark";
            dark_name = "catppuccin-mocha";
            light_name = "catppuccin-latte";
          };
          scrollback.limit = 4000;
          ui.background_opacity = t.opacity;
          security.allow_clipboard_read = true;
          cursor = {
            trail = true;
          };
          keybindings = {
            fold_previous_command = "Ctrl+Shift+S";
          };
          notifications = {
            enabled = true;
          };
        };
      };
    });
  };
}
