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
      {
        name = "dozzle-agent";
        image = "amir20/dozzle:v10.0.7@sha256:d383abf0fee72a8037d6ec6474424e56d752a52208e0ed70f4805e9d86a77830";
        exec = "agent";

        volumes = [
          "/var/run/docker.sock:/var/run/docker.sock:ro"
        ];

        ports = [ "7007:7007" ];
      }

      ###############################################################
      # dumpvdl2-1
      ###############################################################
      {
        name = "dumpvdl2-1";
        image = "ghcr.io/sdr-enthusiasts/docker-dumpvdl2:latest-build-414@sha256:8eba94ff16491c2369a73ebae9dad9918f9e76bc6dab5c109de706c0b94a0128";

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
        image = "ghcr.io/sdr-enthusiasts/docker-dumpvdl2:latest-build-414@sha256:8eba94ff16491c2369a73ebae9dad9918f9e76bc6dab5c109de706c0b94a0128";

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
        image = "ghcr.io/sdr-enthusiasts/docker-dumpvdl2:latest-build-414@sha256:8eba94ff16491c2369a73ebae9dad9918f9e76bc6dab5c109de706c0b94a0128";

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
        image = "ghcr.io/sdr-enthusiasts/docker-dumpvdl2:latest-build-414@sha256:8eba94ff16491c2369a73ebae9dad9918f9e76bc6dab5c109de706c0b94a0128";

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
