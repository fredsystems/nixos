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
    ./wayle
    ./clipboard
    ./hyprlandextra
    ./pamixer
    ./vicinae
  ];

  config = lib.mkIf cfg.enable {
    desktop.environments.modules = {
      wayle.enable = true;
      clipboard.enable = true;
      hyprlandextra.enable = true;
      pamixer.enable = true;
      vicinae.enable = true;
    };
  };
}
