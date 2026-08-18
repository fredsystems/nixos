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

  networking.hostName = "vdlmhub";

  # This host has USB SDR hardware attached; raise the global usbfs
  # transfer-buffer ceiling above the 16 MB kernel default.
  hardware-profile.usbfs.enable = true;

  system.stateVersion = stateVersion;

  sops.secrets = {

    "docker/vdlmhub/dumpvdl2-1.env" = mkContainerSecret "dumpvdl2-1";
    "docker/vdlmhub/dumpvdl2-2.env" = mkContainerSecret "dumpvdl2-2";
    "docker/vdlmhub/dumpvdl2-3.env" = mkContainerSecret "dumpvdl2-3";
    "docker/vdlmhub/dumpvdl2-4.env" = mkContainerSecret "dumpvdl2-4";
  };

  services = {
    adsb.containers = [

      ###############################################################
      # DOZZLE AGENT
      ###############################################################
      (import ../../../modules/services/mk-dozzle-agent.nix { })

      ###############################################################
      # dumpvdl2-1
      ###############################################################
      (config.services.adsb.mkSdrContainer {
        name = "dumpvdl2-1";
        image = "ghcr.io/sdr-enthusiasts/docker-dumpvdl2:latest-build-431@sha256:b2c39bdfd3741f3c37b21d507577d5e485d658f2c9f260e9eadcdd88eaf65812";

        tty = true;
        restart = "always";

        environmentFiles = [
          config.sops.secrets."docker/vdlmhub/dumpvdl2-1.env".path
        ];

        tmpfs = [
          "/var/log"
        ];

        volumes = [
          "/dev:/dev"
        ];
      })

      ###############################################################
      # dumpvdl2-2
      ###############################################################
      (config.services.adsb.mkSdrContainer {
        name = "dumpvdl2-2";
        image = "ghcr.io/sdr-enthusiasts/docker-dumpvdl2:latest-build-431@sha256:b2c39bdfd3741f3c37b21d507577d5e485d658f2c9f260e9eadcdd88eaf65812";

        tty = true;
        restart = "always";

        environmentFiles = [
          config.sops.secrets."docker/vdlmhub/dumpvdl2-2.env".path
        ];

        tmpfs = [
          "/var/log"
        ];

        volumes = [
          "/dev:/dev"
        ];
      })

      ###############################################################
      # dumpvdl2-3
      ###############################################################
      (config.services.adsb.mkSdrContainer {
        name = "dumpvdl2-3";
        image = "ghcr.io/sdr-enthusiasts/docker-dumpvdl2:latest-build-431@sha256:b2c39bdfd3741f3c37b21d507577d5e485d658f2c9f260e9eadcdd88eaf65812";

        tty = true;
        restart = "always";

        environmentFiles = [
          config.sops.secrets."docker/vdlmhub/dumpvdl2-3.env".path
        ];

        tmpfs = [
          "/var/log"
        ];

        volumes = [
          "/dev:/dev"
        ];
      })

      ###############################################################
      # dumpvdl2-4
      ###############################################################
      (config.services.adsb.mkSdrContainer {
        name = "dumpvdl2-4";
        image = "ghcr.io/sdr-enthusiasts/docker-dumpvdl2:latest-build-431@sha256:b2c39bdfd3741f3c37b21d507577d5e485d658f2c9f260e9eadcdd88eaf65812";

        tty = true;
        restart = "always";

        environmentFiles = [
          config.sops.secrets."docker/vdlmhub/dumpvdl2-4.env".path
        ];

        tmpfs = [
          "/var/log"
        ];

        volumes = [
          "/dev:/dev"
        ];
      })
    ];
  };
}
