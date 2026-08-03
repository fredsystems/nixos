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

    # Blacklist the DVB driver to prevent conflicts.
    #
    # Not lib.mkDefault: boot.kernelParams is a list option, and definitions
    # only merge within a single priority level. A mkDefault list is discarded
    # outright by any normal-priority definition elsewhere on the same host,
    # which would silently drop this blacklist. Verified with lib.evalModules:
    #
    #   mkDefault [a] + normal [b]  -> [b]        (a lost)
    #   normal [a]    + normal [b]  -> [b, a]     (merged)
    boot.kernelParams = [ "modprobe.blacklist=dvb_usb_rtl28xxu" ];

    # Add udev rules for RTL-SDR devices
    services.udev.packages = lib.mkDefault [ pkgs.rtl-sdr ];

    # Add user to plugdev group for device access
    users.users.${user}.extraGroups = [ "plugdev" ];
  };
}
