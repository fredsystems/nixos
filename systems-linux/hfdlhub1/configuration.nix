{
  config,
  stateVersion,
  ...
}:
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/secrets/sops.nix
    ../../modules/adsb-docker-units.nix
    ../../modules/monitoring/agent
  ];

  # Server profile
  desktop = {
    enable = false;
    enable_extra = false;
    enable_games = false;
    enable_streaming = false;
  };

  deployment.role = "monitoring-agent";

  sops_secrets.enable_secrets.enable = true;

  networking.hostName = "hfdlhub1";

  #environment.systemPackages = with pkgs; [ ];

  system.stateVersion = stateVersion;

  sops.secrets = {
    "github-token" = { };

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

  system.activationScripts.adsbDockerCompose = {
    text = ''
      # Ensure directory exists (does not touch contents if already there)
      install -d -m0755 -o fred -g users /opt/adsb
    '';
    deps = [ ];
  };

  services = {
    # github-runners = {
    #   runner-1 = {
    #     enable = true;
    #     url = "https://github.com/FredSystems/nixos";
    #     name = "nixos-hfdlhub1-runner-1";
    #     tokenFile = config.sops.secrets."github-token".path;
    #     ephemeral = true;
    #   };

    #   runner-2 = {
    #     enable = true;
    #     url = "https://github.com/FredSystems/nixos";
    #     name = "nixos-hfdlhub1-runner-2";
    #     tokenFile = config.sops.secrets."github-token".path;
    #     ephemeral = true;
    #   };

    # runner-3 = {
    #   enable = true;
    #   url = "https://github.com/FredSystems/nixos";
    #   name = "nixos-hfdlhub1-runner-3";
    #   tokenFile = config.sops.secrets."github-token".path;
    # ephemeral = true;
    # };

    # runner-4 = {
    #   enable = true;
    #   url = "https://github.com/FredSystems/nixos";
    #   name = "nixos-hfdlhub1-runner-4";
    #   tokenFile = config.sops.secrets."github-token".path;
    # ephemeral = true;
    # };
    # };

    adsb.containers = [

      ###############################################################
      # DOZZLE AGENT
      ###############################################################
      {
        name = "dozzle-agent";
        image = "amir20/dozzle:v9.0.3";
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
        image = "ghcr.io/sdr-enthusiasts/docker-dumphfdl:latest-build-180";

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
        image = "ghcr.io/sdr-enthusiasts/docker-dumphfdl:latest-build-180";

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
        image = "ghcr.io/sdr-enthusiasts/docker-dumphfdl:latest-build-180";

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
