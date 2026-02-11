{ lib, ... }:
{
  imports = [
    ../modules/adsb-docker-units.nix
    ../modules/monitoring/agent
    ../modules/github-runners.nix
    ../modules/secrets/sops.nix
  ];

  # Server profile defaults
  desktop = {
    enable = lib.mkDefault false;
    enable_extra = lib.mkDefault false;
    enable_games = lib.mkDefault false;
    enable_streaming = lib.mkDefault false;
  };

  deployment.role = lib.mkDefault "monitoring-agent";
  sops_secrets.enable_secrets.enable = lib.mkDefault true;

  # Standard activation script for ADSB systems
  system.activationScripts.adsbDockerCompose = {
    text = lib.mkDefault ''
      install -d -m0755 -o fred -g users /opt/adsb
    '';
    deps = lib.mkDefault [ ];
  };

  # Standard secrets
  sops.secrets."github-token" = lib.mkDefault { };
}
