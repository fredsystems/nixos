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
  cfg = config.desktop.music;
in
{
  options.desktop.music = {
    enable = lib.mkEnableOption "Music";
  };

  config = lib.mkIf cfg.enable {
    users.users = lib.genAttrs allUsers (_: {
      packages = [ pkgs.cider3 ];
    });
  };
}
