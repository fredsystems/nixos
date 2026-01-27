{
  config,
  pkgs,
  stateVersion,
  ...
}:
let
  hfdlObserver = pkgs.writeText "settings.yaml" (
    builtins.readFile ./docker-data/hfdlobserver/settings.yaml
  );
in
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

  networking.hostName = "hfdlhub2";

  #environment.systemPackages = with pkgs; [ ];

  system.stateVersion = stateVersion;

  sops.secrets = {
    "github-token" = { };

    "docker/hfdlhub2.env" = {
      format = "yaml";
    };
  };

  system.activationScripts.adsbDockerCompose = {
    text = ''
      # Ensure directory exists (does not touch contents if already there)
      install -d -m0755 -o fred -g users /opt/adsb

      install -d -m0755 -o fred -g users /opt/adsb/hfdlobserver

      # Always overwrite the compose file from the Nix store
      install -m0644 -o fred -g users ${hfdlObserver} /opt/adsb/hfdlobserver/settings.yaml
    '';
    deps = [ ];
  };

  services = {
    github-runners = {
      # runner-1 = {
      #   enable = true;
      #   url = "https://github.com/FredSystems/nixos";
      #   name = "nixos-hfdlhub2-runner-1";
      #   tokenFile = config.sops.secrets."github-token".path;
      #   ephemeral = true;
      # };

      # runner-2 = {
      #   enable = true;
      #   url = "https://github.com/FredSystems/nixos";
      #   name = "nixos-hfdlhub2-runner-2";
      #   tokenFile = config.sops.secrets."github-token".path;
      #   ephemeral = true;
      # };

      # runner-3 = {
      #   enable = true;
      #   url = "https://github.com/FredSystems/nixos";
      #   name = "nixos-hfdlhub2-runner-3";
      #   tokenFile = config.sops.secrets."github-token".path;
      # ephemeral = true;
      # };

      # runner-4 = {
      #   enable = true;
      #   url = "https://github.com/FredSystems/nixos";
      #   name = "nixos-hfdlhub2-runner-4";
      #   tokenFile = config.sops.secrets."github-token".path;
      # ephemeral = true;
      # };
    };

    adsb.containers = [
      ###############################################################
      # DOZZLE AGENT
      ###############################################################
      {
        name = "dozzle-agent";
        image = "amir20/dozzle:v9.0.3";
        exec = "agent";

        environmentFiles = [
          config.sops.secrets."docker/hfdlhub2.env".path
        ];

        volumes = [
          "/var/run/docker.sock:/var/run/docker.sock:ro"
        ];

        ports = [ "7007:7007" ];

        requires = [ "network-online.target" ];
      }

      ###############################################################
      # HFDLOBserver
      ###############################################################
      {
        name = "hfdlobserver";
        image = "ghcr.io/sdr-enthusiasts/docker-hfdlobserver:latest-build-15";

        environmentFiles = [
          config.sops.secrets."docker/hfdlhub2.env".path
        ];

        volumes = [
          "/opt/adsb/hfdlobserver:/run/hfdlobserver"
        ];

        requires = [ "network-online.target" ];
      }

    ];
  };
}
