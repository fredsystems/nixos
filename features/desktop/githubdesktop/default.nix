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
  cfg = config.desktop.githubdesktop;
in
{
  options.desktop.githubdesktop = {
    enable = lib.mkEnableOption "GitHub Desktop";
  };

  config = lib.mkIf cfg.enable {
    users.users = lib.genAttrs allUsers (_: {
      packages = with pkgs; [
        github-desktop
      ];
    });
  };
}
