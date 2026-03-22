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
  cfg = config.desktop.vscode;
in
{
  options.desktop.vscode = {
    enable = lib.mkEnableOption "Visual Studio Code";
  };

  config = lib.mkIf cfg.enable {
    users.users = lib.genAttrs allUsers (_: {
      packages = with pkgs; [
        vscode
      ];
    });
  };
}
