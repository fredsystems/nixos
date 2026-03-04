{
  lib,
  config,
  ...
}:
with lib;
let
  cfg = config.desktop.environments.modules;
in
{
  options.desktop.environments.modules = {
    enable = mkOption {
      description = "Install Hyprland/Niri desktop modules.";
      default = false;
    };
  };
  imports = [
    ./fredbar
    ./clipboard
    ./hyprlandextra
    ./pamixer
    ./vicinae
  ];

  config = mkIf cfg.enable {
    desktop.environments.modules = {
      fredbar.enable = true;
      clipboard.enable = true;
      hyprlandextra.enable = true;
      pamixer.enable = true;
      vicinae.enable = true;
    };
  };
}
