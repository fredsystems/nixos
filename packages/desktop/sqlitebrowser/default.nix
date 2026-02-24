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
  cfg = config.desktop.sqlitebrowser;
in
{
  options.desktop.sqlitebrowser = {
    enable = mkOption {
      description = "Enable SQLite Browser.";
      default = false;
    };
  };

  config = mkIf cfg.enable {
    users.users = lib.genAttrs allUsers (_: {
      packages = with pkgs; [
        sqlitebrowser
      ];
    });
  };
}
