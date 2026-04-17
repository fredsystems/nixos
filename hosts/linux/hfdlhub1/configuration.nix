{
  config,
  stateVersion,
  ...
}:
{
  imports = [
    ./hardware-configuration.nix
    ../../../profiles/adsb-hub.nix
  ];

  networking.hostName = "hfdlhub1";

  system.stateVersion = stateVersion;

  sops.secrets = {
    "docker/hfdlhub1/dumphfdl1.env" = {
      format = "yaml";
    };
    "docker/hfdlhub1/dumphfdl2.env" = {
      format = "yaml";
    };
    "docker/hfdlhub1/dumphfdl3.env" = {
      format = "yaml";
    };
  };

  services = {
    adsb.containers = [

      ###############################################################
      # DOZZLE AGENT
      ###############################################################
      (import ../../../modules/services/mk-dozzle-agent.nix { })

      ###############################################################
      # DUMPHFDL-1
      ###############################################################
      {
        name = "dumphfdl-1";
        image = "ghcr.io/sdr-enthusiasts/docker-dumphfdl:latest-build-189@sha256:68a85921e99136b09b3b14cc59101821fb1b4669f6852de8e9c5647caa565faf";

        tty = true;
        restart = "always";

        environmentFiles = [
          config.sops.secrets."docker/hfdlhub1/dumphfdl1.env".path
        ];

        deviceCgroupRules = [
          "c 189:* rwm"
        ];

        tmpfs = [
          "/run:exec,size=64M"
          "/var/log"
          "/tmp"
        ];

        volumes = [
          "/dev:/dev"
          "/opt/adsb/data/dumphfdl1-data:/opt/dumphfdl"
          "/opt/adsb/data/dumphfdl1-scanner:/opt/scanner"
        ];

        requires = [ "network-online.target" ];
      }

      ###############################################################
      # DUMPHFDL-2
      ###############################################################
      {
        name = "dumphfdl-2";
        image = "ghcr.io/sdr-enthusiasts/docker-dumphfdl:latest-build-189@sha256:68a85921e99136b09b3b14cc59101821fb1b4669f6852de8e9c5647caa565faf";

        tty = true;
        restart = "always";

        depends_on = {
          "dumphfdl-1" = {
            condition = "service_started";
          };
        };

        environmentFiles = [
          config.sops.secrets."docker/hfdlhub1/dumphfdl2.env".path
        ];

        deviceCgroupRules = [
          "c 189:* rwm"
        ];

        tmpfs = [
          "/run:exec,size=64M"
          "/var/log"
          "/tmp"
        ];

        volumes = [
          "/dev:/dev"
          "/opt/adsb/data/dumphfdl2-data:/opt/dumphfdl"
          "/opt/adsb/data/dumphfdl2-scanner:/opt/scanner"
        ];
      }

      ###############################################################
      # DUMPHFDL-3
      ###############################################################
      {
        name = "dumphfdl-3";
        image = "ghcr.io/sdr-enthusiasts/docker-dumphfdl:latest-build-189@sha256:68a85921e99136b09b3b14cc59101821fb1b4669f6852de8e9c5647caa565faf";

        tty = true;
        restart = "always";

        depends_on = {
          "dumphfdl-1" = {
            condition = "service_started";
          };
          "dumphfdl-2" = {
            condition = "service_started";
          };
        };

        environmentFiles = [
          config.sops.secrets."docker/hfdlhub1/dumphfdl3.env".path
        ];

        deviceCgroupRules = [
          "c 189:* rwm"
        ];

        tmpfs = [
          "/run:exec,size=64M"
          "/var/log"
          "/tmp"
        ];

        volumes = [
          "/dev:/dev"
          "/opt/adsb/data/dumphfdl3-data:/opt/dumphfdl"
          "/opt/adsb/data/dumphfdl3-scanner:/opt/scanner"
        ];
      }
    ];
  };
}
