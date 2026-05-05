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
    spawn-at-startup = [
      {
        command = [
          "streamcontroller"
          "-b"
        ];
      }
    ];
  };

  wayland.windowManager.hyprland.settings = {
    monitor = hyprMonitors;

    exec-once = [
      "streamcontroller -b"
    ];

    workspace = [
      # Pin workspaces 1-4 to the four physical monitor corners and
      # mark each as the default for that monitor so Hyprland starts
      # them on these IDs (without `default:true` Hyprland reserves
      # the IDs but auto-assigns the next free workspace at startup,
      # which is why they previously came up as 5-8).
      "1, monitor:desc:ASUSTek COMPUTER INC VG27A SALMQS105747, default:true" # top-left
      "2, monitor:desc:ASUSTek COMPUTER INC VG27A SCLMQS041662, default:true" # top-right
      "3, monitor:desc:ASUSTek COMPUTER INC VG27A SALMQS105752, default:true" # bottom-left
      "4, monitor:desc:ASUSTek COMPUTER INC VG27A SALMQS105749, default:true" # bottom-right
    ];

    binde = [
      ", XF86MonBrightnessUp, exec, ~/.config/hyprextra/scripts/backlight.sh 255 --inc"
      ", XF86MonBrightnessDown, exec, ~/.config/hyprextra/scripts/backlight.sh 255 --dec"
    ];
  };
}
