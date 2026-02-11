{ ... }:
{
  imports = [
    ../modules/adsb-docker-units.nix
    ../modules/monitoring/agent
    ../modules/github-runners.nix
    ../modules/secrets/sops.nix
  ];

  # Server profile defaults
  desktop = {
    enable = false;
    enable_extra = false;
    enable_games = false;
    enable_streaming = false;
  };

  deployment.role = "monitoring-agent";
  sops_secrets.enable_secrets.enable = true;

  # Standard activation script for ADSB systems
  system.activationScripts.adsbDockerCompose = {
    text = ''
      install -d -m0755 -o fred -g users /opt/adsb
    '';
    deps = [ ];
  };

  # Standard secrets
  sops.secrets."github-token" = { };
}
