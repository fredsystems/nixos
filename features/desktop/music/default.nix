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
  cfg = config.desktop.music;
in
{
  options.desktop.music = {
    enable = mkOption {
      description = "Enable Music";
      default = false;
    };
  };

  config = mkIf cfg.enable {
    users.users = lib.genAttrs allUsers (_: {
      packages = [ pkgs.cider3 ];
    });
  };
}
