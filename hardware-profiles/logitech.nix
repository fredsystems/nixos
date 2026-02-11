{
  config,
  lib,
  ...
}:
{
  options.hardware-profile.logitech = {
    enable = lib.mkEnableOption "Logitech device USB power management";
  };

  config = lib.mkIf config.hardware-profile.logitech.enable {
    # Prevent USB autosuspend for Logitech devices
    services.udev.extraRules = lib.mkDefault ''
      ACTION=="add", SUBSYSTEM=="usb", TEST=="power/control", ATTR{power/control}="on"
    '';
  };
}
