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
    ../../../profiles/adsb-hub.nix
  ];

  networking.hostName = "hfdlhub2";

  system.stateVersion = stateVersion;

  sops.secrets = {
    "docker/hfdlhub2.env" = {
      format = "yaml";
    };
  };

  # Override the default activation script to include hfdlobserver setup
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
    adsb.containers = [
      ###############################################################
      # DOZZLE AGENT
      ###############################################################
      {
        name = "dozzle-agent";
        image = "amir20/dozzle:v10.0.7@sha256:d383abf0fee72a8037d6ec6474424e56d752a52208e0ed70f4805e9d86a77830";
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
        image = "ghcr.io/sdr-enthusiasts/docker-hfdlobserver:latest-build-19@sha256:294abe7a3583bc3d33617d9ad13245ba8d3e757fdcade99e6f51786395afa995";

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
