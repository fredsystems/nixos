{
  lib,
  config,
  user,
  extraUsers ? [ ],
  ...
}:
let
  cfg = config.desktop.freminal;
  t = config.terminal;
  allUsers = [ user ] ++ extraUsers;
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
        settings = {
          font.family = t.font.family;
          font.size = t.font.size * 1.0;
          theme.name = "catppuccin-mocha";
          scrollback.limit = 4000;
        };
      };
    });
  };
}
