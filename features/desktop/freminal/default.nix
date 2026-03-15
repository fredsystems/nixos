{
  lib,
  config,
  user,
  extraUsers ? [ ],
  ...
}:
let
  cfg = config.desktop.freminal;
  allUsers = [ user ] ++ extraUsers;
in
{
  options.desktop.freminal = {
    enable = lib.mkEnableOption "Enable freminal terminal emulator";
  };

  config = lib.mkIf cfg.enable {
    home-manager.users = lib.genAttrs allUsers (_: {
      programs.freminal = {
        enable = true;
        settings = {
          font.family = "CaskaydiaCove Nerd Font";
          font.size = 14.0;
          theme.name = "catppuccin-mocha";
          scrollback.limit = 4000;
        };
      };
    });
  };
}
