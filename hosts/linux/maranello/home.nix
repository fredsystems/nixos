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

  wayland.windowManager.hyprland.extraConfig = ''
    --------------------
    ---- HOST: MARANELLO
    --------------------

    -- Monitors (generated from modules/compositors/hyprland.nix)
    ${lib.concatStringsSep "\n    " hyprMonitors}

    -- Autostart streamcontroller
    hl.on("hyprland.start", function()
      hl.exec_cmd("streamcontroller -b")
    end)

    -- Pin workspaces 1-4 to the four physical monitor corners and mark each
    -- as the default for that monitor so Hyprland starts them on these IDs.
    hl.workspace_rule({ workspace = "1", monitor = "desc:ASUSTek COMPUTER INC VG27A SALMQS105747", default = true }) -- top-left     (HDMI-A-1)
    hl.workspace_rule({ workspace = "2", monitor = "desc:ASUSTek COMPUTER INC VG27A SALMQS105749", default = true }) -- top-right    (DP-1)
    hl.workspace_rule({ workspace = "3", monitor = "desc:ASUSTek COMPUTER INC VG27A SALMQS105752", default = true }) -- bottom-left  (DP-3)
    hl.workspace_rule({ workspace = "4", monitor = "desc:ASUSTek COMPUTER INC VG27A SCLMQS041662", default = true }) -- bottom-right (DP-2)

    -- Brightness keys (binde -> bind with repeating=true)
    local scripts = os.getenv("HOME") .. "/.config/hyprextra/scripts"
    hl.bind("XF86MonBrightnessUp",   hl.dsp.exec_cmd(scripts .. "/backlight.sh 255 --inc"), { locked = true, repeating = true })
    hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd(scripts .. "/backlight.sh 255 --dec"), { locked = true, repeating = true })
  '';
}
