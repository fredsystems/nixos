{ config, lib, ... }:
{
  imports = [
    ../modules/services/adsb-docker-units.nix
    ../modules/monitoring/agent
    ../modules/services/github-runners.nix
    ../modules/services/github-runners-linux.nix
    ../modules/secrets/sops.nix
    ../modules/data/docker-image-pins.nix
  ];

  deployment.role = lib.mkDefault "monitoring-agent";
  sops_secrets.enable_secrets.enable = lib.mkDefault true;

  # Standard activation script for ADSB systems
  system.activationScripts.adsbDockerCompose = {
    text = lib.mkDefault ''
      install -d -m0755 -o ${config.shared.user.name} -g users /opt/adsb
    '';
    deps = lib.mkDefault [ ];
  };

  # Standard secrets
  sops.secrets."github-token" = lib.mkDefault { };
}
