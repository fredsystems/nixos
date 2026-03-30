{
  lib,
  ...
}:
let
  monitors = import ./monitors.nix;
  hyprMonitors = import ../../../modules/compositors/hyprland.nix {
    inherit lib monitors;
  };
  niriOutputs = import ../../../modules/compositors/niri.nix {
    inherit monitors;
  };
in
{
  # Host-specific Home Manager config for maranello
  imports = [
    ../../../home-profiles/desktop.nix
  ];

  # Maranello-specific Home Manager settings
  programs.niri.settings = {
    outputs = niriOutputs;
  };

  wayland.windowManager.hyprland.settings = {
    monitor = hyprMonitors;

    workspace = [
      "1, monitor:desc:ASUSTek COMPUTER INC VG27A SCLMQS041662"
      "2, monitor:desc:ASUSTek COMPUTER INC VG27A SALMQS105752"
      "3, monitor:desc:ASUSTek COMPUTER INC VG27A SALMQS105747"
      "4, monitor:desc:ASUSTek COMPUTER INC VG27A SALMQS105749"
    ];

    binde = [
      ", XF86MonBrightnessUp, exec, ~/.config/hyprextra/scripts/backlight.sh 255 --inc"
      ", XF86MonBrightnessDown, exec, ~/.config/hyprextra/scripts/backlight.sh 255 --dec"
    ];
  };
}
