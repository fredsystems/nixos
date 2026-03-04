{
  config,
  lib,
  pkgs,
  ...
}:
{
  options.hardware-profile.fingerprint = {
    enable = lib.mkEnableOption "fingerprint reader";
    driver = lib.mkOption {
      type = lib.types.package;
      default = pkgs.libfprint-2-tod1-goodix;
      description = "Fingerprint driver package";
    };
  };

  config = lib.mkIf config.hardware-profile.fingerprint.enable {
    services.fprintd = {
      enable = lib.mkDefault true;
      tod.enable = lib.mkDefault true;
      tod.driver = lib.mkDefault config.hardware-profile.fingerprint.driver;
    };

    security.pam.services = {
      polkit-1.fprintAuth = lib.mkDefault true;
      polkit-gnome-authentication-agent-1.fprintAuth = lib.mkDefault true;
      hyprpolkitagent.fprintAuth = lib.mkDefault true;
    };
  };
}
