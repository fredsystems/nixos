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

  ai.local-llm = {
    enable = true;
    ollamaPackage = inputs.nixpkgs.legacyPackages.${system}.ollama;
    host = "0.0.0.0";
    models = [
      "qwen3-coder:latest"
      "qwen2.5-coder:7b"
      "qwen2.5-coder:32b"
      "deepseek-coder-v2:latest"
      "qwen3.5:9b"
    ];
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
