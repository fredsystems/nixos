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
        enable = true;
        enable_extra = lib.mkDefault true;
      };

      nas = {
        enable = true;
        mounts = config.shared.nasMounts.standard;
      };

      shared.enableStandardWifi = true;

      hardware.i2c.enable = true;
      users.users.${user}.extraGroups = [ "i2c" ];

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

      deployment.role = "desktop";
      sops_secrets.enable_secrets.enable = true;
    }

    # Conditional: Solaar
    (lib.mkIf config.profile.desktop.enableSolaar {
      services.solaar = {
        enable = true;
        package = pkgs.solaar;
        window = "hide";
        batteryIcons = "regular";
        extraArgs = "";
      };
      services.udev.packages = with pkgs; [ solaar ];
    })

    # Conditional: U2F
    (lib.mkIf config.profile.desktop.enableU2F {
      security.pam.services = {
        polkit-1.u2fAuth = true;
        polkit-gnome-authentication-agent-1.u2fAuth = true;
        hyprpolkitagent.u2fAuth = true;
      };
    })
  ];
}
