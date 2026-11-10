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
    ./clipboard
    ./hyprlandextra
    ./noctalia
    ./pamixer
    ./vicinae
  ];

  config = lib.mkIf cfg.enable {
    desktop.environments.modules = {
      clipboard.enable = lib.mkDefault true;
      hyprlandextra.enable = lib.mkDefault true;
      noctalia.enable = lib.mkDefault true;
      pamixer.enable = lib.mkDefault true;
      vicinae.enable = lib.mkDefault true;
    };
  };
}
