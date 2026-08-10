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
      inherit (pkgs) lib;

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

      # Verifies the flake-input -> CI-category mapping agrees across all
      # four locations that hold a copy of it (the `# CI:` comments in
      # flake.nix, the two workflow `input_category` arrays, and the
      # impacted-hosts script's `INPUT_CATEGORY`).
      #
      # This was previously enforced only by an agent remembering the
      # `nixos-input-category-sync` skill, and that failed silently:
      # `nixpkgs-kernel` shipped with a `# CI: server` comment but was
      # absent from both bash arrays, so it fell through to the `global`
      # default and every monthly kernel bump rebuilt two desktops that
      # no-op the pin. Under-building is the worse failure in the same
      # class, hence a machine check rather than a documented habit.
      inputCategorySync = pkgs.writeShellApplication {
        name = "check-input-category-sync";
        runtimeInputs = [ pkgs.python3 ];
        text = ''
          script=".opencode/skills/projects/nixos-input-category-sync/scripts/check-input-category-sync.py"

          if [ ! -f "$script" ]; then
            echo "error: $script not found (run from the repository root)" >&2
            exit 1
          fi

          python3 "$script"
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
      # classified in four places (the `# CI:` comment, ci-linux.yaml,
      # ci-darwin.yaml and the impacted-hosts script) per the input-category
      # sync invariant, which is a lot of ceremony for a build-time-only tool.
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

              input-category-sync = {
                enable = true;
                name = "flake input CI category sync (4 locations)";
                entry = "${pkgs.lib.getExe inputCategorySync}";

                # Fires on any file that holds a copy of the mapping, plus
                # flake.lock (which decides *which* inputs must be present in
                # each copy -- adding an input there without updating the
                # arrays is the exact drift this catches). pass_filenames is
                # off because the checker always cross-references the full
                # set; a single-file view cannot detect disagreement.
                files = "^(flake\\.nix|flake\\.lock|\\.github/workflows/ci-(linux|darwin)\\.yaml|\\.opencode/skills/projects/nixos-(eval-impacted-hosts/scripts/impacted-hosts\\.sh|input-category-sync/scripts/check-input-category-sync\\.py))$";
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

      # Standalone check so `nix flake check` and CI catch category drift
      # even when the pre-commit hook is bypassed or the change arrives by
      # a route that never ran hooks (bot PRs, web edits).

      # Enforces that the decoder heartbeat list in loki-ruler.nix matches the
      # containers actually declared on each host.
      #
      # This drifted in production: acarsdec-3 was replaced by xng on
      # acarshub, the host config was updated, and the heartbeat list was not.
      # DecoderHeartbeatMissing then fired continuously for a container that
      # no longer existed, while the container that replaced it went entirely
      # unmonitored. The file carried a comment saying the list "must track
      # the services.adsb.containers definitions"; a comment is not an
      # enforcement mechanism.
      #
      # Only decoder containers are required to be covered. Sidecars like
      # dozzle-agent have no heartbeat and are not expected in the list, so
      # the check is one-directional plus a stale-entry test: every unit named
      # in decoderUnits must exist on its host, and any container matching a
      # known decoder-image prefix must be covered.
      decoder-units-sync =
        let
          decoderPrefixes = [
            "acarsdec"
            "dumpvdl2"
            "dumphfdl"
            "hfdlobserver"
            "dump978"
            "xng"
          ];

          hostsWithDecoders = lib.filterAttrs (
            _: cfg: (cfg.config.services.adsb.containers or [ ]) != [ ]
          ) self.nixosConfigurations;

          # unit name as it appears in the ruler, per host
          actualUnits = lib.mapAttrs (
            _: cfg: map (c: "docker-${c.name}.service") cfg.config.services.adsb.containers
          ) hostsWithDecoders;

          # containers whose name starts with a known decoder prefix
          expectedUnits = lib.mapAttrs (
            _: cfg:
            map (c: "docker-${c.name}.service") (
              lib.filter (
                c: lib.any (prefix: lib.hasPrefix prefix c.name) decoderPrefixes
              ) cfg.config.services.adsb.containers
            )
          ) hostsWithDecoders;

          covered = self.nixosConfigurations.sdrhub.config.monitoring.decoderUnits;
          coveredByHost = lib.mapAttrs (_: units: map (d: d.unit) units) (lib.groupBy (d: d.host) covered);

          # 1. every covered unit must exist on its host
          stale = lib.flatten (
            map (
              d:
              let
                onHost = actualUnits.${d.host} or [ ];
              in
              lib.optional (
                !lib.elem d.unit onHost
              ) "  stale: ${d.host} has no ${d.unit} (heartbeat rule fires forever)"
            ) covered
          );

          # 2. every decoder container must be covered
          uncovered = lib.flatten (
            lib.mapAttrsToList (
              host: units:
              map (u: "  uncovered: ${host} runs ${u} with no heartbeat rule") (
                lib.subtractLists (coveredByHost.${host} or [ ]) units
              )
            ) expectedUnits
          );

          problems = stale ++ uncovered;
        in
        pkgs.runCommand "decoder-units-sync-check" { } (
          if problems == [ ] then
            ''
              echo "decoder heartbeat coverage OK (${toString (builtins.length covered)} units)"
              touch "$out"
            ''
          else
            ''
              echo "decoder heartbeat list is out of sync with the host configs:" >&2
              ${lib.concatMapStringsSep "\n" (p: "echo ${lib.escapeShellArg p} >&2") problems}
              echo "" >&2
              echo "Update decoderUnits in modules/monitoring/master/loki-ruler.nix." >&2
              exit 1
            ''
        );

      input-category-sync =
        pkgs.runCommand "input-category-sync-check"
          {
            nativeBuildInputs = [ inputCategorySync ];
          }
          ''
            cd ${self}
            check-input-category-sync
            touch "$out"
          '';
    }
  );
}
