{
  config,
  inputs,
  system,
  stateVersion,
  ...
}:
{
  imports = [
    ./hardware-configuration.nix
    ../../../profiles/adsb-hub.nix
    ../../../modules/services/attic/attic_server.nix
  ];

  ai = {
    local-llm = {
      enable = true;
      ollamaPackage = inputs.nixpkgs.legacyPackages.${system}.ollama;
      host = "0.0.0.0";
      models = [
        "qwen3.6:latest"
        "gemma4:latest"
      ];
    };
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
