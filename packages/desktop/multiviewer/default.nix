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
  cfg = config.desktop.multiviewer;
in
{
  options.desktop.multiviewer = {
    enable = mkOption {
      description = "Enable Multiviewer for F1.";
      default = false;
    };
  };

  config = mkIf cfg.enable {
    users.users = lib.genAttrs allUsers (_: {
      packages = with pkgs; [
        multiviewer-for-f1
      ];
    });
  };
}
