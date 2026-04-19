{
  config,
  ...
}:
{
  imports = [
    ../../../profiles/darwin.nix
    ../../../modules/services/github-runners.nix
  ];

  sops.secrets."github-token" = { };

  ci.githubRunners = {
    enable = true;
    repo = "FredSystems/nixos";
    defaultTokenFile = config.sops.secrets."github-token".path;
    runnerCount = 4;
  };
}
