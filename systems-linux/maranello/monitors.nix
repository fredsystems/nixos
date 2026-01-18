# modules/monitors/model.nix
{
  DP-3 = {
    width = 2560;
    height = 1440;
    refresh = 144.0;
    scale = 1.0;
    x = 0;
    y = 0;
  };

  DP-2 = {
    width = 2560;
    height = 1440;
    refresh = 144.0;
    scale = 1.0;
    x = -2560;
    y = 0;
  };

  HDMI-A-1 = {
    width = 2560;
    height = 1440;
    refresh = 60.0;
    scale = 1.0;
    x = -2560;
    y = -1440;
  };

  DP-1 = {
    width = 2560;
    height = 1440;
    refresh = 144.0;
    scale = 1.0;
    x = 0;
    y = -1440;
  };
}
