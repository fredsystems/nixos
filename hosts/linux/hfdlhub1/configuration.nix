{
  config,
  stateVersion,
  ...
}:
let
  inherit (import ../../../modules/services/mk-container-secret.nix)
    mkContainerSecret
    ;

in
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
    "docker/hfdlhub1/dumphfdl1.env" = mkContainerSecret "dumphfdl-1";
    "docker/hfdlhub1/dumphfdl2.env" = mkContainerSecret "dumphfdl-2";
    "docker/hfdlhub1/dumphfdl3.env" = mkContainerSecret "dumphfdl-3";
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
        image = "ghcr.io/sdr-enthusiasts/docker-dumphfdl:latest-build-201@sha256:3de816c1cfc7f89b40574faaa8e175dd76b8f4c31e88744c68a8de5f21d5219a";

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
        image = "ghcr.io/sdr-enthusiasts/docker-dumphfdl:latest-build-201@sha256:3de816c1cfc7f89b40574faaa8e175dd76b8f4c31e88744c68a8de5f21d5219a";

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
        image = "ghcr.io/sdr-enthusiasts/docker-dumphfdl:latest-build-201@sha256:3de816c1cfc7f89b40574faaa8e175dd76b8f4c31e88744c68a8de5f21d5219a";

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
