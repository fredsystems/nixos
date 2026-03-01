{
  pkgs,
  config,
  stateVersion,
  ...
}:
{
  imports = [
    ./hardware-configuration.nix
    ../../profiles/adsb-hub.nix
    ../../modules/attic/attic_server.nix
  ];

  ai.local-llm = {
    enable = true;
    ollamaPackage = pkgs.ollama;
    host = "0.0.0.0";
  };

  media.jellyfin = {
    enable = true;
  };

  networking.hostName = "fredhub";

  system.stateVersion = stateVersion;

  ci.githubRunners = {
    enable = true;
    repo = "FredSystems/nixos";
    defaultTokenFile = config.sops.secrets."github-token".path;
    runnerCount = 4; # Auto-generates runner-1 through runner-4
  };
}
