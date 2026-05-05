# Monitor data for maranello, keyed by "Make Model Serial" description.
# This format is matched directly by niri (since 0.1.9) and with desc: prefix by Hyprland.
#
# Physical layout (verified by blinking each output via `hyprctl dispatch dpms off <name>`):
#
#   ┌────────────────────────┬────────────────────────┐
#   │ top-left               │ top-right              │
#   │ HDMI-A-1 / SALMQS105747│ DP-1     / SALMQS105749│
#   │ (-2560, -1440)         │ (0, -1440)             │
#   ├────────────────────────┼────────────────────────┤
#   │ bottom-left            │ bottom-right           │
#   │ DP-3     / SALMQS105752│ DP-2     / SCLMQS041662│
#   │ (-2560, 0)             │ (0, 0)                 │
#   └────────────────────────┴────────────────────────┘
#
# Note: Hyprland's runtime auto-arrangement of overlapping/missing-coord
# monitors does NOT reflect physical reality on this host -- the coords
# below are the source of truth and were validated by user observation.
{
  # Top-left (HDMI-A-1)
  "ASUSTek COMPUTER INC VG27A SALMQS105747" = {
    width = 2560;
    height = 1440;
    refresh = 144.0;
    scale = 1.0;
    x = -2560;
    y = -1440;
  };

  # Top-right (DP-1)
  "ASUSTek COMPUTER INC VG27A SALMQS105749" = {
    width = 2560;
    height = 1440;
    refresh = 144.0;
    scale = 1.0;
    x = 0;
    y = -1440;
  };

  # Bottom-left (DP-3)
  "ASUSTek COMPUTER INC VG27A SALMQS105752" = {
    width = 2560;
    height = 1440;
    refresh = 144.0;
    scale = 1.0;
    x = -2560;
    y = 0;
  };

  # Bottom-right (DP-2)
  "ASUSTek COMPUTER INC VG27A SCLMQS041662" = {
    width = 2560;
    height = 1440;
    refresh = 144.0;
    scale = 1.0;
    x = 0;
    y = 0;
  };
}
