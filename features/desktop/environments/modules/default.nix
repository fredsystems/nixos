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
    ./pamixer
    ./vicinae
    ./wayle
  ];

  config = lib.mkIf cfg.enable {
    desktop.environments.modules = {
      clipboard.enable = true;
      hyprlandextra.enable = true;
      pamixer.enable = true;
      vicinae.enable = true;
      wayle.enable = true;
    };
  };
}
