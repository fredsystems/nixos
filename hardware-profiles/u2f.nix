{
  config,
  lib,
  ...
}:
{
  options.hardware-profile.u2f = {
    enable = lib.mkEnableOption "U2F/FIDO2 authentication";
  };

  config = lib.mkIf config.hardware-profile.u2f.enable {
    security.pam.services = {
      polkit-1.u2fAuth = lib.mkDefault true;
      polkit-gnome-authentication-agent-1.u2fAuth = lib.mkDefault true;
      hyprpolkitagent.u2fAuth = lib.mkDefault true;
    };
  };
}
