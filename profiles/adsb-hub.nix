{ lib, user, ... }:
{
  imports = [
    ../modules/adsb-docker-units.nix
    ../modules/monitoring/agent
    ../modules/github-runners.nix
    ../modules/secrets/sops.nix
  ];

  deployment.role = lib.mkDefault "monitoring-agent";
  sops_secrets.enable_secrets.enable = lib.mkDefault true;

  # Standard activation script for ADSB systems
  system.activationScripts.adsbDockerCompose = {
    text = lib.mkDefault ''
      install -d -m0755 -o ${user} -g users /opt/adsb
    '';
    deps = lib.mkDefault [ ];
  };

  # Standard secrets
  sops.secrets."github-token" = lib.mkDefault { };
}
