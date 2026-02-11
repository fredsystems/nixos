{
  config,
  lib,
  pkgs,
  user,
  ...
}:
{
  options.hardware-profile.rtl-sdr = {
    enable = lib.mkEnableOption "RTL-SDR USB device support";
  };

  config = lib.mkIf config.hardware-profile.rtl-sdr.enable {
    hardware.rtl-sdr.enable = lib.mkDefault true;

    # Blacklist the DVB driver to prevent conflicts
    boot.kernelParams = lib.mkDefault [ "modprobe.blacklist=dvb_usb_rtl28xxu" ];

    # Add udev rules for RTL-SDR devices
    services.udev.packages = lib.mkDefault [ pkgs.rtl-sdr ];

    # Add user to plugdev group for device access
    users.users.${user}.extraGroups = lib.mkDefault [ "plugdev" ];
  };
}
