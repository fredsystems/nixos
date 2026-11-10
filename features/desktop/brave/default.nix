{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.desktop.brave;
  allUsers = config.shared.allUsers;
in
{
  options.desktop.brave = {
    enable = lib.mkEnableOption "Brave browser";
  };

  config = lib.mkIf cfg.enable {
    users.users = lib.genAttrs allUsers (_: {
      packages = with pkgs; [
        brave
      ];
    });

    home-manager.users = lib.genAttrs allUsers (_: {
      programs.brave = {
        enable = true;
      };

      catppuccin.brave.enable = true;
    });
  };
}
