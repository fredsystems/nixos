{
  lib,
  pkgs,
  config,
  user,
  extraUsers ? [ ],
  ...
}:
with lib;
let
  allUsers = [ user ] ++ extraUsers;
  cfg = config.desktop.obs;
in
{
  options.desktop.obs = {
    # Updated to match the new configuration
    enable = mkOption {
      description = "Enable StreamLab";
      default = false;
    };
  };

  config = mkIf cfg.enable {
    services.udev = {
      packages = with pkgs; [
        streamcontroller
      ];
    };

    users.users = lib.genAttrs allUsers (_: {
      packages = with pkgs; [
        obs-studio
        obs-studio-plugins.wlrobs
        obs-studio-plugins.obs-vkcapture
        streamcontroller
      ];
    });

    home-manager.users = lib.genAttrs allUsers (_: {
      programs.obs-studio = {
        enable = true;
      };

      catppuccin.obs.enable = true;
    });
  };
}
