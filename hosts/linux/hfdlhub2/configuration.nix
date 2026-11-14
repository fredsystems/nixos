{
  config,
  pkgs,
  ...
}:
let
  inherit (import ../../../modules/services/mk-container-secret.nix)
    mkContainerSecrets
    ;

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

  # The activation script below copies settings.yaml into /opt/adsb, where
  # the container reads it once at start, so nothing restarted the container
  # when the file changed: a deploy updated the file and left hfdlobserver
  # running the old settings (Plan 05 cleanup 5.11). Tying the unit to the
  # file's store path restarts it exactly when the settings change.
  systemd.services.docker-hfdlobserver.restartTriggers = [ hfdlObserver ];

  sops.secrets = {
    "docker/hfdlhub2.env" = mkContainerSecrets [
      "dozzle-agent"
      "hfdlobserver"
    ];
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
        image = config.shared.dockerImages.dozzle;
        environmentFiles = [
          config.sops.secrets."docker/hfdlhub2.env".path
        ];
      })

      ###############################################################
      # HFDLOBserver
      ###############################################################
      {
        name = "hfdlobserver";
        image = config.shared.dockerImages.hfdlobserver;

        environmentFiles = [
          config.sops.secrets."docker/hfdlhub2.env".path
        ];

        volumes = [
          "/opt/adsb/hfdlobserver:/run/hfdlobserver"
        ];

      }

    ];
  };
}
