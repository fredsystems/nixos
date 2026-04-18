{
  config,
  ...
}:
{
  imports = [
    ../../../profiles/darwin.nix
    ../../../features/ai/opencode
    ../../../modules/services/github-runners.nix
  ];

  ai = {
    opencode.enable = true;
  };

  sops.secrets."github-token" = { };

  ci.githubRunners = {
    enable = true;
    repo = "FredSystems/nixos";
    defaultTokenFile = config.sops.secrets."github-token".path;
    runnerCount = 2;
  };
}
