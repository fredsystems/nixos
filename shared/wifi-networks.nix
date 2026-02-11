{ config, lib, ... }:
{
  # Define standard WiFi profiles that can be imported by any system
  options.shared.wifiProfiles = lib.mkOption {
    type = lib.types.attrs;
    default = {
      "Home" = {
        connection.id = "Home";
        connection.type = "wifi";
        wifi.ssid = "$home_ssid";
        wifi-security = {
          key-mgmt = "wpa-psk";
          psk = "$home_psk";
        };
      };
      "Work" = {
        connection.id = "Work";
        connection.type = "wifi";
        wifi.ssid = "$work_ssid";
        wifi-security = { };
      };
      "Parents" = {
        connection.id = "Parents";
        connection.type = "wifi";
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
      enable = true;
      ensureProfiles = {
        environmentFiles = [ config.sops.secrets."wifi.env".path ];
        profiles = config.shared.wifiProfiles;
      };
    };
  };
}
