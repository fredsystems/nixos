# Monitor data for maranello, keyed by "Make Model Serial" description.
# This format is matched directly by niri (since 0.1.9) and with desc: prefix by Hyprland.
#
# Physical layout (as Hyprland actually arranges them at runtime):
#
#   ┌────────────────────────┬────────────────────────┐
#   │ top-left               │ top-right              │
#   │ SALMQS105747           │ SCLMQS041662           │
#   │ (-2560, -1440)         │ (0, -1440)             │
#   ├────────────────────────┼────────────────────────┤
#   │ bottom-left            │ bottom-right           │
#   │ SALMQS105752           │ SALMQS105749           │
#   │ (-2560, 0)             │ (0, 0)                 │
#   └────────────────────────┴────────────────────────┘
{
  # Top-left
  "ASUSTek COMPUTER INC VG27A SALMQS105747" = {
    width = 2560;
    height = 1440;
    refresh = 144.0;
    scale = 1.0;
    x = -2560;
    y = -1440;
  };

  # Top-right
  "ASUSTek COMPUTER INC VG27A SCLMQS041662" = {
    width = 2560;
    height = 1440;
    refresh = 144.0;
    scale = 1.0;
    x = 0;
    y = -1440;
  };

  # Bottom-left
  "ASUSTek COMPUTER INC VG27A SALMQS105752" = {
    width = 2560;
    height = 1440;
    refresh = 144.0;
    scale = 1.0;
    x = -2560;
    y = 0;
  };

  # Bottom-right
  "ASUSTek COMPUTER INC VG27A SALMQS105749" = {
    width = 2560;
    height = 1440;
    refresh = 144.0;
    scale = 1.0;
    x = 0;
    y = 0;
  };
}
