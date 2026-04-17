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

  networking.hostName = "vdlmhub";

  system.stateVersion = stateVersion;

  sops.secrets = {

    "docker/vdlmhub/dumpvdl2-1.env" = {
      format = "yaml";
    };
    "docker/vdlmhub/dumpvdl2-2.env" = {
      format = "yaml";
    };
    "docker/vdlmhub/dumpvdl2-3.env" = {
      format = "yaml";
    };
    "docker/vdlmhub/dumpvdl2-4.env" = {
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
      # dumpvdl2-1
      ###############################################################
      {
        name = "dumpvdl2-1";
        image = "ghcr.io/sdr-enthusiasts/docker-dumpvdl2:latest-build-418@sha256:1e74b0a7b5ff75edfafdd2fbfbdab43ff3811072ab563d0c37fdbb3cf8c58903";

        tty = true;
        restart = "always";

        environmentFiles = [
          config.sops.secrets."docker/vdlmhub/dumpvdl2-1.env".path
        ];

        deviceCgroupRules = [
          "c 189:* rwm"
        ];

        tmpfs = [
          "/run:exec,size=64M"
          "/var/log"
        ];

        volumes = [
          "/dev:/dev"
        ];
      }

      ###############################################################
      # dumpvdl2-2
      ###############################################################
      {
        name = "dumpvdl2-2";
        image = "ghcr.io/sdr-enthusiasts/docker-dumpvdl2:latest-build-418@sha256:1e74b0a7b5ff75edfafdd2fbfbdab43ff3811072ab563d0c37fdbb3cf8c58903";

        tty = true;
        restart = "always";

        environmentFiles = [
          config.sops.secrets."docker/vdlmhub/dumpvdl2-2.env".path
        ];

        deviceCgroupRules = [
          "c 189:* rwm"
        ];

        tmpfs = [
          "/run:exec,size=64M"
          "/var/log"
        ];

        volumes = [
          "/dev:/dev"
        ];
      }

      ###############################################################
      # dumpvdl2-3
      ###############################################################
      {
        name = "dumpvdl2-3";
        image = "ghcr.io/sdr-enthusiasts/docker-dumpvdl2:latest-build-418@sha256:1e74b0a7b5ff75edfafdd2fbfbdab43ff3811072ab563d0c37fdbb3cf8c58903";

        tty = true;
        restart = "always";

        environmentFiles = [
          config.sops.secrets."docker/vdlmhub/dumpvdl2-3.env".path
        ];

        deviceCgroupRules = [
          "c 189:* rwm"
        ];

        tmpfs = [
          "/run:exec,size=64M"
          "/var/log"
        ];

        volumes = [
          "/dev:/dev"
        ];
      }

      ###############################################################
      # dumpvdl2-4
      ###############################################################
      {
        name = "dumpvdl2-4";
        image = "ghcr.io/sdr-enthusiasts/docker-dumpvdl2:latest-build-418@sha256:1e74b0a7b5ff75edfafdd2fbfbdab43ff3811072ab563d0c37fdbb3cf8c58903";

        tty = true;
        restart = "always";

        environmentFiles = [
          config.sops.secrets."docker/vdlmhub/dumpvdl2-4.env".path
        ];

        deviceCgroupRules = [
          "c 189:* rwm"
        ];

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
