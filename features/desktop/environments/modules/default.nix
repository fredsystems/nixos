{
  lib,
  config,
  ...
}:
let
  cfg = config.desktop.environments.modules;
  inherit (config.desktop.environments.shell) provider;
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
      wayle.enable = provider == "wayle";
    };
  };
}
