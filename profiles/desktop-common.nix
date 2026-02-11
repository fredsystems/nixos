{
  config,
  lib,
  user,
  ...
}:

{
  imports = [
    ../hardware-profiles
    ../modules/nas-system.nix
    ../modules/secrets/sops.nix
    ../shared/nas-mounts.nix
    ../shared/wifi-networks.nix
  ];

  options.profile.desktop = {
    # Hardware profile options are now in hardware-profiles/*
  };

  config = lib.mkMerge [
    # Always enable for desktop profile
    {
      desktop = {
        enable = lib.mkDefault true;
        enable_extra = lib.mkDefault true;
      };

      nas = {
        enable = lib.mkDefault true;
        mounts = lib.mkDefault config.shared.nasMounts.standard;
      };

      shared.enableStandardWifi = lib.mkDefault true;

      # Enable hardware profiles for desktop systems
      hardware-profile.i2c.enable = lib.mkDefault true;
      hardware-profile.u2f.enable = lib.mkDefault true;

      # Standard email secrets for desktops
      sops.secrets = {
        "wifi.env" = { };
        "email/natca/signature" = {
          owner = user;
          mode = "0600";
        };
        "email/icloud/signature" = {
          owner = user;
          mode = "0600";
        };
        "email/icloud/caldav_server" = {
          owner = user;
          mode = "0600";
        };
        "email/icloud/address" = {
          owner = user;
          mode = "0600";
        };
        "email/icloud/password" = {
          owner = user;
          mode = "0600";
        };
      };

      deployment.role = lib.mkDefault "desktop";
      sops_secrets.enable_secrets.enable = lib.mkDefault true;
    }
  ];
}
