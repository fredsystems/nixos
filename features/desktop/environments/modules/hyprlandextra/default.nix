{
  lib,
  config,
  user,
  extraUsers ? [ ],
  pkgs,
  ...
}:
with lib;
let
  allUsers = [ user ] ++ extraUsers;
  cfg = config.desktop.environments.modules.hyprlandextra;
in
{
  options.desktop.environments.modules.hyprlandextra = {
    enable = mkOption {
      description = "Enable extra stuff for hyprland.";
      default = false;
    };
  };

  config = mkIf cfg.enable {
    home-manager.users = lib.genAttrs allUsers (_: {
      systemd.user.services.caffeine-inhibit = {
        Unit = {
          Description = "Caffeine idle inhibitor";
        };

        Service = {
          Type = "simple";
          ExecStart = ''
            ${pkgs.systemd}/bin/systemd-inhibit \
              --what=idle:sleep \
              --who=caffeine \
              --why=User-requested-stay-awake \
              ${pkgs.coreutils}/bin/sleep infinity
          '';
        };
      };

      home.file.".config/hyprextra/" = {
        source = ./hyprextra;
        recursive = true;
      };
    });
  };
}
