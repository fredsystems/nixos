{ config, lib, ... }:
{
  # Define standard WiFi profiles that can be imported by any system
  options.shared.wifiProfiles = lib.mkOption {
    type = lib.types.attrs;
    default = {
      "Home" = {
        connection = {
          id = "Home";
          type = "wifi";
        };
        wifi.ssid = "$home_ssid";
        wifi-security = {
          key-mgmt = "wpa-psk";
          psk = "$home_psk";
        };
      };
      "Work" = {
        connection = {
          id = "Work";
          type = "wifi";
          autoconnect = false;
        };
        wifi.ssid = "$work_ssid";
        wifi-security = { };
      };
      "Work-Secret" = {
        connection = {
          id = "Work-Secret";
          type = "wifi";
          autoconnect = false;
        };
        wifi.ssid = "$work_secret_ssid";
        wifi-security = {
          key-mgmt = "wpa-psk";
          psk = "$work_secret_psk";
        };
      };
      "Parents" = {
        connection = {
          id = "Parents";
          type = "wifi";
          autoconnect = false;
        };
        wifi.ssid = "$parents_ssid";
        wifi-security = {
          key-mgmt = "wpa-psk";
          psk = "$parents_psk";
        };
      };
    };
    description = "Centralized WiFi profile definitions";
  };

  # Helper to enable WiFi with standard profiles
  options.shared.enableStandardWifi = lib.mkEnableOption "standard WiFi profiles";

  config = lib.mkIf config.shared.enableStandardWifi {
    networking.networkmanager = {
      enable = lib.mkDefault true;
      ensureProfiles = {
        environmentFiles = lib.mkDefault [ config.sops.secrets."wifi.env".path ];
        profiles = lib.mkDefault config.shared.wifiProfiles;
      };
    };
  };
}
