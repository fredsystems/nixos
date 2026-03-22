{
  lib,
  pkgs,
  config,
  user,
  extraUsers ? [ ],
  ...
}:
let
  allUsers = [ user ] ++ extraUsers;
  cfg = config.desktop.missioncenter;
in
{
  options.desktop.missioncenter = {
    enable = lib.mkEnableOption "Mission Center";
  };

  config = lib.mkIf cfg.enable {
    users.users = lib.genAttrs allUsers (_: {
      packages = with pkgs; [
        mission-center
      ];
    });
  };
}
