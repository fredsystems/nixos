{
  config,
  stateVersion,
  ...
}:
{
  imports = [
    ./hardware-configuration.nix
    ../../../profiles/adsb-hub.nix
    ../../../modules/hardware/usbfs.nix
  ];

  networking.hostName = "hfdlhub1";

  # This host has USB SDR hardware attached; raise the global usbfs
  # transfer-buffer ceiling above the 16 MB kernel default.
  hardware-profile.usbfs.enable = true;

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
        image = "ghcr.io/sdr-enthusiasts/docker-dumphfdl:latest-build-200@sha256:df87d1e74639ec5bfd634e0ef64c21cce1f44fe00b878736e14b3199dff470b9";

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

      }

      ###############################################################
      # DUMPHFDL-2
      ###############################################################
      {
        name = "dumphfdl-2";
        image = "ghcr.io/sdr-enthusiasts/docker-dumphfdl:latest-build-200@sha256:df87d1e74639ec5bfd634e0ef64c21cce1f44fe00b878736e14b3199dff470b9";

        tty = true;
        restart = "always";

        # Serialise startup against the sibling decoders: all three share
        # the sdrplay_apiService and three RSP1a devices, and starting in
        # parallel races for them. Previously written as Compose's
        # `depends_on`, which this module never read.
        dependsOn = [ "dumphfdl-1" ];

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
        image = "ghcr.io/sdr-enthusiasts/docker-dumphfdl:latest-build-200@sha256:df87d1e74639ec5bfd634e0ef64c21cce1f44fe00b878736e14b3199dff470b9";

        tty = true;
        restart = "always";

        dependsOn = [
          "dumphfdl-1"
          "dumphfdl-2"
        ];

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
