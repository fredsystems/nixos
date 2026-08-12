{ lib, ... }:
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
      # NO "vps" ENTRY. It was removed rather than repaired.
      #
      # It pointed at fredclausen.com with the default port 22, but fredvps's
      # sshd is on 2269, so `sync-compose <dir> vps` could never connect -- it
      # just SYNed a closed port and tripped the ssh-decoy tripwire. Deploys to
      # that host go through colmena (flake/hosts/servers.nix, which correctly
      # sets targetPort = 2269), so this predated colmena and had no remaining
      # caller.
      #
      # Fixing the port was the wrong repair: it would have preserved a second,
      # undocumented deploy path to the one internet-facing host in the fleet.
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
