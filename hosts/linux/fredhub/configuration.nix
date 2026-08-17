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
    ./nginx.nix
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
    # Auto-generates runner-1 through runner-8.
    #
    # fredhub is the only Linux runner host, and ci-linux.yaml's matrix can
    # fan out to 9 hosts, so 4 was the throughput ceiling for a full-fleet
    # rebuild. The box is 32 cores / 125 GiB with ~120 GiB genuinely
    # available; an idle runner costs ~65 MiB, so the runners themselves are
    # free. See the max-jobs note below before raising this further.
    runnerCount = 8;
  };
}
