{
  config,
  lib,
  ...
}:
{
  options.hardware-profile.graphics = {
    enable = lib.mkEnableOption "graphics acceleration";
    enable32Bit = lib.mkEnableOption "32-bit graphics support";
  };

  config = lib.mkIf config.hardware-profile.graphics.enable {
    hardware.graphics = {
      enable = lib.mkDefault true;
      enable32Bit = lib.mkDefault config.hardware-profile.graphics.enable32Bit;
    };
  };
}
