{
  pkgs,
  config,
  stateVersion,
  ...
}:
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/secrets/sops.nix
    ../../modules/monitoring/agent
    ../../modules/github-runners.nix
    ../../modules/attic/attic_server.nix
  ];

  # Server profile
  desktop = {
    enable = false;
    enable_extra = false;
    enable_games = false;
    enable_streaming = false;
  };

  ai.local-llm = {
    enable = true;
    ollamaPackage = pkgs.ollama;
    host = "0.0.0.0";
  };

  media.jellyfin = {
    enable = true;
  };

  deployment.role = "monitoring-agent";

  sops_secrets.enable_secrets.enable = true;

  networking.hostName = "fredhub";

  # environment.systemPackages = with pkgs; [
  # ];

  system.stateVersion = stateVersion;

  sops.secrets = {
    "github-token" = { };
  };

  ci.githubRunners = {
    enable = true;
    repo = "FredSystems/nixos";
    defaultTokenFile = config.sops.secrets."github-token".path;

    runners = {
      runner-1 = {
        url = "https://github.com/FredSystems/nixos";
        tokenFile = config.sops.secrets."github-token".path;
      };

      runner-2 = {
        url = "https://github.com/FredSystems/nixos";
        tokenFile = config.sops.secrets."github-token".path;
      };

      runner-3 = {
        url = "https://github.com/FredSystems/nixos";
        tokenFile = config.sops.secrets."github-token".path;
      };

      runner-4 = {
        url = "https://github.com/FredSystems/nixos";
        tokenFile = config.sops.secrets."github-token".path;
      };
    };
  };
}
