# Flake checks, run per supported system.
#
# Usage:
#   nix flake check
#   nix build .#checks.x86_64-linux.pre-commit-check
#   nix build .#checks.x86_64-linux.prometheus-alert-rules
{
  inputs,
  self,
  forAllSystems,
  ...
}:
{
  checks = forAllSystems (
    system:
    let
      pkgs = import inputs.nixpkgs { inherit system; };
    in
    {
      pre-commit-check = inputs.precommit-base.lib.mkCheck {
        inherit system;

        src = self;

        extraExcludes = [
          "secrets.yaml"
          "tsconfig.json"
        ];
      };

      # Alerting rules are configuration, and configuration that is never
      # executed rots silently. Prometheus reports a rule that matches nothing
      # as health=ok, so a rule referring to a metric that does not exist, or
      # one whose expression can never be true, looks identical to a healthy
      # rule. Five such rules accumulated in this repo before anyone noticed.
      #
      # `check rules` catches syntax and template errors. `test rules`
      # evaluates each alert against synthetic series and asserts what fires,
      # which is the only thing that catches a rule that is valid but wrong.
      prometheus-alert-rules =
        pkgs.runCommand "prometheus-alert-rules-check"
          {
            nativeBuildInputs = [ pkgs.prometheus.cli ];
          }
          ''
            cd ${self}/modules/monitoring/master/alert-rules

            echo "==> promtool check rules"
            promtool check rules ./*.yaml

            echo "==> promtool test rules"
            cd tests
            promtool test rules ./*.yaml

            touch "$out"
          '';
    }
  );
}
