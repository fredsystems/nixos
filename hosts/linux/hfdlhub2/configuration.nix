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
      (import ../../../modules/services/mk-dozzle-agent.nix {
        environmentFiles = [
          config.sops.secrets."docker/hfdlhub2.env".path
        ];
      })

      ###############################################################
      # HFDLOBserver
      ###############################################################
      {
        name = "hfdlobserver";
        image = "ghcr.io/sdr-enthusiasts/docker-hfdlobserver:latest-build-21@sha256:38ca7d6593f8368f0e537eb5c8f75414e6e27fdb9b01532409779c6579130028";

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
