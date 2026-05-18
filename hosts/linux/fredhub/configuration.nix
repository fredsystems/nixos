{
  config,
  inputs,
  system,
  stateVersion,
  lib,
  ...
}:
let
  unstablePkgs = import inputs.nixpkgs {
    inherit system;
    config.allowUnfreePredicate =
      pkg:
      builtins.elem (lib.getName pkg) [
        "open-webui"
      ];
  };
in
{
  imports = [
    ./hardware-configuration.nix
    ../../../profiles/adsb-hub.nix
    ../../../modules/services/attic/attic_server.nix
  ];

  nixpkgs.config.allowUnfreePredicate =
    pkg:
    builtins.elem (lib.getName pkg) [
      "open-webui"
    ];

  ai = {
    local-llm = {
      enable = true;
      ollamaPackage = unstablePkgs.ollama;
      openwebPackage = unstablePkgs.open-webui;
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
