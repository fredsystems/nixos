{
  config,
  stateVersion,
  ...
}:
let
  inherit (import ../../../modules/services/mk-container-secret.nix)
    mkContainerSecrets
    ;

in
{
  imports = [
    ./hardware-configuration.nix
    ../../../profiles/adsb-hub.nix
    ../../../modules/hardware/usbfs.nix
  ];

  networking.hostName = "acarshub";

  # This host has USB SDR hardware attached; raise the global usbfs
  # transfer-buffer ceiling above the 16 MB kernel default.
  hardware-profile.usbfs.enable = true;

  system.stateVersion = stateVersion;

  sops.secrets = {
    "docker/acarshub.env" = mkContainerSecrets [
      "acarsdec-1"
      "acarsdec-2"
      "acarsdec-3"
      "dozzle-agent"
    ];
  };

  services = {
    adsb.containers = [
      ###############################################################
      # DOZZLE AGENT
      ###############################################################
      (import ../../../modules/services/mk-dozzle-agent.nix {
        environmentFiles = [
          config.sops.secrets."docker/acarshub.env".path
        ];
      })

      ###############################################################
      # ACARSDEC-1
      ###############################################################
      {
        name = "acarsdec-1";
        image = "ghcr.io/sdr-enthusiasts/docker-acarsdec:latest-build-502@sha256:6fa61ab3ff70340e660e6f3ae2a322e446fa78e509b139a18311473494639f20";

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
        image = "ghcr.io/sdr-enthusiasts/docker-acarsdec:latest-build-502@sha256:6fa61ab3ff70340e660e6f3ae2a322e446fa78e509b139a18311473494639f20";

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
      # XNG
      ###############################################################
      {
        name = "xng";
        image = "ghcr.io/sdr-enthusiasts/docker-xng:latest-build-2@sha256:5378dde090a05a14db4225899c78ba4626daa46cbe0ad6d74d8f9e410a5e423b";

        tty = true;
        restart = "always";

        environmentFiles = [
          config.sops.secrets."docker/acarshub.env".path
        ];

        deviceCgroupRules = [
          "c 189:* rwm"
        ];

        environment = {
          XNG_SERIAL = "00012095";
          XNG_CHANNELS = "131.85;131.825;131.725;131.65;131.55;131.525;131.475;131.45;131.425;131.25;131.125;130.85;130.825;130.55;130.45;130.425";
          XNG_STATION_ID = "CS-KABQ-ACARS";
          XNG_VERBOSE = "1";
          XNG_ZMQ = "tcp://0.0.0.0:5555";
          XNG_MODE = "acars";
          XNG_DRIVER = "rtlsdr";
          XNG_CENTER = "131.1375M";
          XNG_SAMPLE_RATE = "2400000";
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
