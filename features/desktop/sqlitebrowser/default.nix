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
  cfg = config.desktop.sqlitebrowser;
in
{
  options.desktop.sqlitebrowser = {
    enable = lib.mkEnableOption "SQLite Browser";
  };

  config = lib.mkIf cfg.enable {
    users.users = lib.genAttrs allUsers (_: {
      packages = with pkgs; [
        sqlitebrowser
      ];
    });
  };
}
