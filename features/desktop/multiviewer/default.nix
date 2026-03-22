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
  cfg = config.desktop.multiviewer;
in
{
  options.desktop.multiviewer = {
    enable = lib.mkEnableOption "Multiviewer for F1";
  };

  config = lib.mkIf cfg.enable {
    users.users = lib.genAttrs allUsers (_: {
      packages = with pkgs; [
        multiviewer-for-f1
      ];
    });
  };
}
