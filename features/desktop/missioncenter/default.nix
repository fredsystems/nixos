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
  cfg = config.desktop.missioncenter;
in
{
  options.desktop.missioncenter = {
    enable = mkOption {
      description = "Enable missioncenter for F1.";
      default = false;
    };
  };

  config = mkIf cfg.enable {
    users.users = lib.genAttrs allUsers (_: {
      packages = with pkgs; [
        mission-center
      ];
    });
  };
}
