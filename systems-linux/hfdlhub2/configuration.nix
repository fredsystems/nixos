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
    ../../profiles/adsb-hub.nix
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
        image = "amir20/dozzle:v10.0.6@sha256:4815df572d135ce24c14ec3c150e482c98693bc5cc20291693b582baab8eb0bf";
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
        image = "ghcr.io/sdr-enthusiasts/docker-hfdlobserver:latest-build-18@sha256:22d55177f789b1608881f440506bbbb8fd09eb19427a1662c4bffb6d41f247d8";

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
