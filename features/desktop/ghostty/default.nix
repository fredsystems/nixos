{
  lib,
  config,
  user,
  extraUsers ? [ ],
  isDarwin,
  ...
}:

let
  allUsers = [ user ] ++ extraUsers;
  cfg = config.desktop.ghostty;
  t = config.terminal;
  isLinux = !isDarwin;
in
{
  imports = [ ../../../modules/terminal/common.nix ] ++ lib.optional isLinux ./linux-xdg.nix;

  options.desktop.ghostty = {
    enable = lib.mkEnableOption "Ghostty terminal emulator";
  };

  config = lib.mkIf cfg.enable {
    home-manager.users = lib.genAttrs allUsers (_: {
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
