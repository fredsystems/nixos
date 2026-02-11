{
  lib,
  ...
}:
let
  monitors = import ./monitors.nix;
  hyprMonitors = import ../../modules/monitors/hyprland.nix {
    inherit lib monitors;
  };
  niriOutputs = import ../../modules/monitors/niri.nix {
    inherit monitors;
  };
in
{
  # Host-specific Home Manager config for maranello
  imports = [
    ../../profiles/home-desktop.nix
  ];

  # Maranello-specific Home Manager settings
  programs.niri.settings = {
    outputs = niriOutputs;
  };

  wayland.windowManager.hyprland.settings = {
    monitor = hyprMonitors;

    workspace = [
      "1, monitor:DP-3"
      "2, monitor:DP-2"
      "3, monitor:HDMI-A-1"
      "4, monitor:DP-1"
    ];

    binde = [
      ", XF86MonBrightnessUp, exec, ~/.config/hyprextra/scripts/backlight.sh 255 --inc"
      ", XF86MonBrightnessDown, exec, ~/.config/hyprextra/scripts/backlight.sh 255 --dec"
    ];
  };
}
