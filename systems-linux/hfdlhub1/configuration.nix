{
  config,
  stateVersion,
  ...
}:
{
  imports = [
    ./hardware-configuration.nix
    ../../profiles/adsb-hub.nix
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
      {
        name = "dozzle-agent";
        image = "amir20/dozzle:v10.0.6@sha256:4815df572d135ce24c14ec3c150e482c98693bc5cc20291693b582baab8eb0bf";
        exec = "agent";

        volumes = [
          "/var/run/docker.sock:/var/run/docker.sock:ro"
        ];

        ports = [ "7007:7007" ];
      }

      ###############################################################
      # DUMPHFDL-1
      ###############################################################
      {
        name = "dumphfdl-1";
        image = "ghcr.io/sdr-enthusiasts/docker-dumphfdl:latest-build-185@sha256:db3c7ae033fb6e94b787e7fa134361b60b9bab7273db11faf1a977f3803c397f";

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
        image = "ghcr.io/sdr-enthusiasts/docker-dumphfdl:latest-build-185@sha256:db3c7ae033fb6e94b787e7fa134361b60b9bab7273db11faf1a977f3803c397f";

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
        image = "ghcr.io/sdr-enthusiasts/docker-dumphfdl:latest-build-185@sha256:db3c7ae033fb6e94b787e7fa134361b60b9bab7273db11faf1a977f3803c397f";

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
