{
  lib,
  config,
  user,
  extraUsers ? [ ],
  ...
}:
with lib;
let
  allUsers = [ user ] ++ extraUsers;
  cfg = config.desktop.environments.modules.vicinae;
in
{
  options.desktop.environments.modules.vicinae = {
    enable = mkOption {
      description = "Enable vicinae.";
      default = false;
    };
  };

  config = mkIf cfg.enable {
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
