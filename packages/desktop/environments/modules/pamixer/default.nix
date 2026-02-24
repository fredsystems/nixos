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
  cfg = config.desktop.environments.modules.pamixer;
in
{
  options.desktop.environments.modules.pamixer = {
    enable = mkOption {
      description = "Enable pamixer.";
      default = false;
    };
  };

  config = mkIf cfg.enable {
    users.users = lib.genAttrs allUsers (_: {
      packages = with pkgs; [
        pamixer
      ];
    });
  };
}
