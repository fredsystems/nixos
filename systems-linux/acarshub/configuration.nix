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

  networking.hostName = "acarshub";

  system.stateVersion = stateVersion;

  sops.secrets = {
    "docker/acarshub.env" = {
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
        image = "amir20/dozzle:v10.0.4";
        exec = "agent";

        environmentFiles = [
          config.sops.secrets."docker/acarshub.env".path
        ];

        volumes = [
          "/var/run/docker.sock:/var/run/docker.sock:ro"
        ];

        ports = [ "7007:7007" ];

        requires = [ "network-online.target" ];
      }

      ###############################################################
      # ACARSDEC-1
      ###############################################################
      {
        name = "acarsdec-1";
        image = "ghcr.io/sdr-enthusiasts/docker-acarsdec:latest-build-482";

        tty = true;
        restart = "always";

        environmentFiles = [
          config.sops.secrets."docker/acarshub.env".path
        ];

        deviceCgroupRules = [
          "c 189:* rwm"
        ];

        environment = {
          SERIAL = "00012785";
          FREQUENCIES = "131.85;131.825;131.725;131.65;131.55;131.525;131.475;131.45;131.425;131.25;131.125;130.85;130.825;130.55;130.45;130.425";
          FEED_ID = "CS-KABQ-ACARS";
          OUTPUT_SERVER = "192.168.31.20";
          OUTPUT_SERVER_MODE = "tcp";
          OUTPUT_SERVER_PORT = "5550";
        };

        tmpfs = [
          "/run:exec,size=64M"
          "/var/log"
        ];

        volumes = [
          "/dev:/dev"
        ];
      }

      ###############################################################
      # ACARSDEC-2
      ###############################################################
      {
        name = "acarsdec-2";
        image = "ghcr.io/sdr-enthusiasts/docker-acarsdec:latest-build-482";

        tty = true;
        restart = "always";

        environmentFiles = [
          config.sops.secrets."docker/acarshub.env".path
        ];

        deviceCgroupRules = [
          "c 189:* rwm"
        ];

        environment = {
          SERIAL = "00013305";
          FREQUENCIES = "130.025;129.9;129.525;129.35;129.125;129.0";
          FEED_ID = "CS-KABQ-ACARS";
          OUTPUT_SERVER = "192.168.31.20";
          OUTPUT_SERVER_MODE = "tcp";
          OUTPUT_SERVER_PORT = "5550";
        };

        tmpfs = [
          "/run:exec,size=64M"
          "/var/log"
        ];

        volumes = [
          "/dev:/dev"
        ];
      }

      ###############################################################
      # ACARSDEC-3
      ###############################################################
      {
        name = "acarsdec-3";
        image = "ghcr.io/sdr-enthusiasts/docker-acarsdec:latest-build-482";

        tty = true;
        restart = "always";

        environmentFiles = [
          config.sops.secrets."docker/acarshub.env".path
        ];

        deviceCgroupRules = [
          "c 189:* rwm"
        ];

        environment = {
          SERIAL = "00012095";
          FREQUENCIES = "136.975;136.8;136.65";
          FEED_ID = "CS-KABQ-ACARS";
          OUTPUT_SERVER = "192.168.31.20";
          OUTPUT_SERVER_MODE = "tcp";
          OUTPUT_SERVER_PORT = "5550";
        };

        tmpfs = [
          "/run:exec,size=64M"
          "/var/log"
        ];

        volumes = [
          "/dev:/dev"
        ];
      }
    ];
  };
}
