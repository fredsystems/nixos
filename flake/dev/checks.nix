# Pre-commit checks, run per supported system.
# Wired up via precommit-base (FredSystems/pre-commit-checks).
#
# Usage:
#   nix flake check
#   nix build .#checks.x86_64-linux.pre-commit-check
{
  inputs,
  self,
  forAllSystems,
  ...
}:
{
  checks = forAllSystems (system: {
    pre-commit-check = inputs.precommit-base.lib.mkCheck {
      inherit system;

      src = self;

      extraExcludes = [
        "secrets.yaml"
        "tsconfig.json"
      ];
    };
  });
}
