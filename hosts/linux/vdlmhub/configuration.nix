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
        image = "ghcr.io/sdr-enthusiasts/docker-dumpvdl2:latest-build-422@sha256:9266807c9436bc0ab5ca4888cc87e02e163e0e7a295267710a6b5e9f8defb853";

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
        image = "ghcr.io/sdr-enthusiasts/docker-dumpvdl2:latest-build-422@sha256:9266807c9436bc0ab5ca4888cc87e02e163e0e7a295267710a6b5e9f8defb853";

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
        image = "ghcr.io/sdr-enthusiasts/docker-dumpvdl2:latest-build-422@sha256:9266807c9436bc0ab5ca4888cc87e02e163e0e7a295267710a6b5e9f8defb853";

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
        image = "ghcr.io/sdr-enthusiasts/docker-dumpvdl2:latest-build-422@sha256:9266807c9436bc0ab5ca4888cc87e02e163e0e7a295267710a6b5e9f8defb853";

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
