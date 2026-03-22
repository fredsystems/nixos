{
  lib,
  config,
  user,
  extraUsers ? [ ],
  ...
}:
let
  allUsers = [ user ] ++ extraUsers;
  cfg = config.desktop.environments.modules.vicinae;
in
{
  options.desktop.environments.modules.vicinae = {
    enable = lib.mkEnableOption "vicinae";
  };

  config = lib.mkIf cfg.enable {
    home-manager.users = lib.genAttrs allUsers (_: {
      programs.vicinae = {
        enable = true;
        systemd = {
          enable = true;
        };
      };
      catppuccin.vicinae.enable = true;
    });
  };
}
