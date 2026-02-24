{
  lib,
  pkgs,
  config,
  user,
  extraUsers ? [ ],
  system,
  ...
}:

let
  allUsers = [ user ] ++ extraUsers;
  cfg = config.desktop.ghostty;
  t = config.terminal;
  isDarwin = lib.hasSuffix "darwin" system;
  isLinux = !isDarwin;
in
{
  imports = [ ../../../modules/terminal/common.nix ] ++ lib.optional isLinux ./linux-xdg.nix;

  options.desktop.ghostty = {
    enable = lib.mkEnableOption "Enable Ghostty terminal emulator";
  };

  config = lib.mkIf cfg.enable {
    home-manager.users = lib.genAttrs allUsers (_: {
      home.packages = [ pkgs.ghostty ];

      programs.ghostty = {
        enable = true;

        settings = {
          font-family = t.font.family;
          font-size = t.font.size;
          background-opacity = t.opacity;
        };
      };

      catppuccin.ghostty.enable = true;
    });
  };
}
