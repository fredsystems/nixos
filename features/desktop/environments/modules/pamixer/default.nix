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
  cfg = config.desktop.environments.modules.pamixer;
in
{
  options.desktop.environments.modules.pamixer = {
    enable = lib.mkEnableOption "pamixer";
  };

  config = lib.mkIf cfg.enable {
    users.users = lib.genAttrs allUsers (_: {
      packages = with pkgs; [
        pamixer
      ];
    });
  };
}
