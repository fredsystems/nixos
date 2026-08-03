{
  config,
  lib,
  ...
}:
let
  cfg = config.hardware-profile.usbfs;
in
{
  options.hardware-profile.usbfs = {
    enable = lib.mkEnableOption "raised usbfs buffer ceiling for USB SDR receivers";

    memoryMB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1000;
      example = 2000;
      description = ''
        Value for the usbcore.usbfs_memory_mb kernel parameter: the ceiling on
        memory userspace may pin for USB transfer buffers. This is a limit, not
        an allocation, so raising it consumes nothing.

        The kernel default is 16 MB, a compile-time constant that does not vary
        with RAM, chipset, or USB controller. librtlsdr pins roughly 3.75 MB per
        device (15 transfers of 256 KB), so four RTL-SDRs sit at about 15 MB and
        exhaust the default ceiling. The symptom is "Failed to submit transfer"
        and "async read failed" from dumpvdl2.

        The limit is global rather than per-device, so it must scale with the
        number of radios attached to a host, not with the host's capability.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # usbcore is built into the kernel on these hosts rather than being a
    # loadable module, so boot.extraModprobeConfig has no effect -- modprobe.d
    # only applies to modules that are actually loaded. The parameter has to
    # come from the kernel command line.
    #
    # Deliberately not lib.mkDefault: boot.kernelParams is a list option, and
    # a mkDefault list is discarded outright (not merged) by any
    # normal-priority definition elsewhere.
    boot.kernelParams = [ "usbcore.usbfs_memory_mb=${toString cfg.memoryMB}" ];

    # Apply on activation as well, so the setting takes effect without waiting
    # for a reboot. The kernel parameter above remains authoritative from boot.
    systemd.tmpfiles.rules = [
      "w /sys/module/usbcore/parameters/usbfs_memory_mb - - - - ${toString cfg.memoryMB}"
    ];
  };
}
