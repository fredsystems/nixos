{ lib, user, ... }:
{
  # Define standard sync-compose hosts that can be imported by any system
  options.shared.syncHosts = lib.mkOption {
    type = lib.types.listOf lib.types.attrs;
    default = [
      {
        name = "sdrhub";
        ip = "192.168.31.20";
        directory = "sdrhub";
        remotePath = "/opt/adsb";
        port = "22";
        legacyScp = false;
      }
      {
        name = "hfdlhub-1";
        ip = "192.168.31.19";
        directory = "hfdlhub-1";
        remotePath = "/opt/adsb";
        port = "22";
        legacyScp = false;
      }
      {
        name = "hfdlhub-2";
        ip = "192.168.31.17";
        directory = "hfdlhub-2";
        remotePath = "/opt/adsb";
        port = "22";
        legacyScp = false;
      }
      {
        name = "acarshub";
        ip = "192.168.31.24";
        directory = "acarshub";
        remotePath = "/opt/adsb";
        port = "22";
        legacyScp = false;
      }
      {
        name = "vdlmhub";
        ip = "192.168.31.23";
        directory = "vdlmhub";
        remotePath = "/opt/adsb";
        port = "22";
        legacyScp = false;
      }
      {
        name = "vps";
        ip = "fredclausen.com";
        directory = "vps";
        remotePath = "/home/${user}";
        port = "22";
        legacyScp = false;
      }
      {
        name = "brandon";
        ip = "73.242.200.187";
        directory = "brandon";
        remotePath = "/opt/adsb";
        port = "3222";
        legacyScp = true;
      }
    ];
    description = "Centralized sync-compose host definitions";
  };
}
