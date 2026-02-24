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
  cfg = config.desktop.githubdesktop;
in
{
  options.desktop.githubdesktop = {
    enable = mkOption {
      description = "Enable GitHub Desktop.";
      default = false;
    };
  };

  config = mkIf cfg.enable {
    users.users = lib.genAttrs allUsers (_: {
      packages = with pkgs; [
        github-desktop
      ];
    });
  };
}
