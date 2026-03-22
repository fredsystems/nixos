{
  lib,
  config,
  ...
}:
let
  cfg = config.desktop.environments.modules;
in
{
  options.desktop.environments.modules = {
    enable = lib.mkEnableOption "Hyprland/Niri desktop modules";
  };
  imports = [
    ./fredbar
    ./clipboard
    ./hyprlandextra
    ./pamixer
    ./vicinae
  ];

  config = lib.mkIf cfg.enable {
    desktop.environments.modules = {
      fredbar.enable = true;
      clipboard.enable = true;
      hyprlandextra.enable = true;
      pamixer.enable = true;
      vicinae.enable = true;
    };
  };
}
