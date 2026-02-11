{
  config,
  lib,
  pkgs,
  user,
  ...
}:

{
  imports = [
    ../modules/nas-system.nix
    ../modules/secrets/sops.nix
    ../shared/nas-mounts.nix
    ../shared/wifi-networks.nix
  ];

  options.profile.desktop = {
    enableSolaar = lib.mkEnableOption "Solaar Logitech device support";
    enableU2F = lib.mkEnableOption "U2F authentication";
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

      hardware.i2c.enable = lib.mkDefault true;
      users.users.${user}.extraGroups = lib.mkDefault [ "i2c" ];

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

    # Conditional: Solaar
    (lib.mkIf config.profile.desktop.enableSolaar {
      services.solaar = {
        enable = lib.mkDefault true;
        package = lib.mkDefault pkgs.solaar;
        window = lib.mkDefault "hide";
        batteryIcons = lib.mkDefault "regular";
        extraArgs = lib.mkDefault "";
      };
      services.udev.packages = with pkgs; [ solaar ];
    })

    # Conditional: U2F
    (lib.mkIf config.profile.desktop.enableU2F {
      security.pam.services = {
        polkit-1.u2fAuth = lib.mkDefault true;
        polkit-gnome-authentication-agent-1.u2fAuth = lib.mkDefault true;
        hyprpolkitagent.u2fAuth = lib.mkDefault true;
      };
    })
  ];
}
