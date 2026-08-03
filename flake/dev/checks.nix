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

      excludes = [
        "secrets.yaml"
        "tsconfig.json"
      ];

      # Validates the Prometheus alerting rules: `check rules` for syntax and
      # templates, `test rules` for behaviour.
      #
      # Shared by the standalone flake check and the pre-commit hook below so
      # the two can never diverge.
      #
      # Both halves matter. `check rules` catches malformed YAML and bad label
      # templates. `test rules` is the only thing that catches a rule which is
      # valid but wrong -- Prometheus reports a rule matching nothing as
      # health=ok, so an expression that can never be true looks identical to a
      # healthy rule with nothing to report. Five such rules accumulated here
      # before anyone noticed.
      alertRuleCheck = pkgs.writeShellApplication {
        name = "check-prometheus-alert-rules";
        runtimeInputs = [ pkgs.prometheus.cli ];
        text = ''
          rules_dir="modules/monitoring/master/alert-rules"

          if [ ! -d "$rules_dir" ]; then
            echo "error: $rules_dir not found (run from the repository root)" >&2
            exit 1
          fi

          echo "==> promtool check rules"
          promtool check rules "$rules_dir"/*.yaml

          echo "==> promtool test rules"
          # promtool resolves rule_files relative to the test file, so the unit
          # tests must be run from their own directory.
          cd "$rules_dir/tests"
          promtool test rules ./*.yaml
        '';
      };
    in
    {
      # precommit-base exposes composable modules (`{ hooks, excludes,
      # passthru }`) as well as the `mkCheck` convenience wrapper. mkCheck
      # takes no extra-hooks argument, so this merges the base hook set with a
      # repo-local hook and calls git-hooks' `run` directly.
      #
      # git-hooks is reached through precommit-base's own inputs rather than
      # being added as a new input to this flake. A new input would have to be
      # classified in four places (the `# CI:` comment, agents.md, ci-linux.yaml
      # and the impacted-hosts script) per the input-category sync invariant,
      # which is a lot of ceremony for a build-time-only tool.
      pre-commit-check =
        let
          base = inputs.precommit-base.lib.mkBaseCheck {
            inherit system;
            extraExcludes = excludes;
          };

          gitHooks = inputs.precommit-base.inputs.git-hooks;

          run = gitHooks.lib.${system}.run {
            src = self;
            inherit (base) excludes;

            hooks = base.hooks // {
              prometheus-alert-rules = {
                enable = true;
                name = "prometheus alert rules (promtool check + test)";
                entry = "${pkgs.lib.getExe alertRuleCheck}";

                # Fires when a rule file or its tests change. pass_filenames is
                # off because the script globs the directory itself: a rule file
                # and its test file must always be validated together, and
                # promtool needs the whole set to resolve rule_files.
                files = "^modules/monitoring/master/alert-rules/.*\\.ya?ml$";
                pass_filenames = false;
              };
            };
          };
        in
        run
        // {
          inherit (base) passthru;
          shellHook = run.shellHook or "";
          enabledPackages = run.enabledPackages or [ ];
        };

      # Standalone check, so CI and `nix flake check` can validate the rules
      # without running the whole hook suite.
      prometheus-alert-rules =
        pkgs.runCommand "prometheus-alert-rules-check"
          {
            nativeBuildInputs = [ alertRuleCheck ];
          }
          ''
            cd ${self}
            check-prometheus-alert-rules
            touch "$out"
          '';
    }
  );
}
