{
  pkgs,
  config,
  stateVersion,
  ...
}:
{

  # Procedure for generating RS256 secret for Attic server token:
  # sudo mkdir -p /etc/attic
  # sudo bash -c 'nix run nixpkgs#openssl -- genrsa -traditional 4096 | base64 -w0 > /etc/attic/rs256.secret'
  # sudo bash -c 'echo "ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64=\"$(cat /etc/attic/rs256.secret)\"" > /etc/attic/atticd.env'
  # sudo chmod 600 /etc/attic/atticd.env
  # sudo rm /etc/attic/rs256.secret
  # atticd-atticadm make-token --validity "12y" --sub "fred" --push "fred" --pull "fred" --create-cache "fred"
  # attic login local http://localhost:8080 <token above>
  # attic cache create fred

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
