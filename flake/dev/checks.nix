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

      # Binary files that the content-rewriting hooks must not touch.
      #
      # Those hooks are configured with `types: [file]` rather than `[text]`,
      # so they do not skip binaries on their own: `mixed-line-ending`
      # rewrites any CRLF byte pair it finds inside a brotli-compressed font,
      # silently producing a file that no longer decodes (verified -- it grew
      # a subsetted Font Awesome face by one byte and broke `TTFont()`).
      #
      # Applied per-hook rather than being appended to `excludes` above,
      # which applies to EVERY base hook. That would also take `.woff2` out of
      # `check-added-large-files`, whose 600 kB ceiling is precisely what
      # should stop someone committing a non-subsetted 1.5 MB face. Only the
      # hooks that rewrite file contents need to skip these.
      binaryExcludes = [ "\\.woff2$" ];

      excludeBinaries =
        hooks:
        lib.genAttrs [
          "trailing-whitespace"
          "mixed-line-ending"
          "end-of-file-fixer"
        ] (name: hooks.${name} // { excludes = (hooks.${name}.excludes or [ ]) ++ binaryExcludes; });

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

      # Verifies that every local script/action ci-linux.yaml and
      # ci-darwin.yaml shell out to directly is registered in the matching
      # FORCE_ALL_FILES array in scripts/impacted-hosts.sh -- see that
      # script's own header and the nixos-ci-pipeline-file-sync skill for
      # why this is a mechanical check rather than a documented habit.
      ciPipelineFilesSync = pkgs.writeShellApplication {
        name = "check-ci-pipeline-files-sync";
        text = ''
          script="scripts/check-ci-pipeline-files-sync.sh"

          if [ ! -f "$script" ]; then
            echo "error: $script not found (run from the repository root)" >&2
            exit 1
          fi

          bash "$script"
        '';
      };

      # Verifies that no two image pins in modules/data/docker-image-pins.nix
      # are on adjacent lines. Renovate opens one PR per image from the same
      # base, and git conflicts on adjacent-line edits, so without the
      # spacing the merge queue keeps ejecting bumps whose neighbour landed
      # first. See scripts/check-docker-pin-spacing.sh's header.
      dockerPinSpacingCheck = pkgs.writeShellApplication {
        name = "check-docker-pin-spacing";
        text = ''
          bash scripts/check-docker-pin-spacing.sh
        '';
      };

      # Verifies the sops age-recipient set is consistent across
      # modules/secrets/.sops.yaml's `keys:` anchors, its creation_rules
      # entry for secrets.yaml, and the recipients actually embedded in
      # secrets.yaml's own (unencrypted) sops metadata.
      #
      # Adding a recipient (new host, key rotation) requires a manual
      # follow-up step -- `sops updatekeys secrets.yaml` -- documented only
      # as a comment in modules/secrets/sops.nix. Nothing enforced it. Miss
      # it and the new/rotated host fails to decrypt at deploy time, on
      # real hardware, instead of at review time. No decryption key is
      # needed: sops embeds who it encrypted for in the clear, so this
      # check runs anywhere, including CI runners with none of the 12
      # private keys.
      sopsRecipientsCheck = pkgs.writeShellApplication {
        name = "check-sops-recipients";
        runtimeInputs = [
          pkgs.yq-go
          pkgs.jq
        ];
        text = ''
          bash scripts/check-sops-recipients.sh
        '';
      };

      # Verifies two doc/config invariants that were previously in sync
      # only by luck: MODULES.md documents exactly the modules exported by
      # `nixosModules`, and the desktop/server host split (`desktop_names`
      # in ci-linux.yaml vs. flake/hosts/servers.nix) is self-consistent.
      #
      # ACTUAL_MODULES_JSON / ALL_SYSTEMS_JSON / SERVERS_NIX_KEYS_JSON are
      # baked in at build time from already-evaluated Nix values
      # (`self.nixosModules`, `self.nixosConfigurations`,
      # flake/hosts/servers.nix) rather than left for the script to fetch
      # via `nix eval` at runtime. That matters here specifically because
      # this SAME derivation is used both as the pre-commit hook entry
      # below and as the standalone `checks.doc-drift` -- and git-hooks'
      # own `run` derivation (what `nix build .#checks.pre-commit-check`
      # and CI's lint job exercise) runs the WHOLE hook suite inside a
      # sandboxed Nix build with the nix-command feature disabled and no
      # daemon-socket access, so a runtime `nix eval` call from inside a
      # hook fails there unconditionally, commit-time invocation or not.
      # (See scripts/check-doc-drift.sh's header: the script itself still
      # falls back to a live `nix eval` when these env vars are unset, for
      # convenience when a human runs it directly.)
      docDriftCheck = pkgs.writeShellApplication {
        name = "check-doc-drift";
        runtimeInputs = [ pkgs.jq ];
        text = ''
          export ACTUAL_MODULES_JSON=${lib.escapeShellArg (builtins.toJSON (lib.attrNames self.nixosModules))}
          export ALL_SYSTEMS_JSON=${lib.escapeShellArg (builtins.toJSON (lib.attrNames self.nixosConfigurations))}
          export SERVERS_NIX_KEYS_JSON=${lib.escapeShellArg (builtins.toJSON (lib.attrNames (import ../hosts/servers.nix)))}
          bash scripts/check-doc-drift.sh
        '';
      };

      # Detects `.nix` files that are never imported anywhere and are not
      # themselves a recognised entry point (flake.nix, flake/**, a host's
      # configuration.nix/hardware-configuration.nix/home.nix, or a
      # profiles/*.nix).
      #
      # `firmware.nix` used to sit in this repo imported by nothing, while CI
      # still treated any change to it as a global rebuild trigger. It has
      # since been deleted, so this check currently has no subject on the
      # current tree -- that is fine and is the point: it is preventative,
      # not remedial. See scripts/check-module-reachability.sh's header for
      # the full design and its deliberate false-negative bias.
      moduleReachabilityCheck = pkgs.writeShellApplication {
        name = "check-module-reachability";
        text = ''
          bash scripts/check-module-reachability.sh
        '';
      };

      # Asserts that every `mkOption { ... }` call declares both a `type`
      # (so a bad value is an eval-time error, not a silent no-op) and a
      # `description` (so the option is discoverable without reading the
      # defining module). An audit found one option with no type at all and
      # roughly seventeen with no description; both classes are now fixed,
      # and this check is what keeps them from coming back. See
      # scripts/check-option-schema.sh's header for the brace-matching
      # parse strategy and its documented limitation.
      optionSchemaCheck = pkgs.writeShellApplication {
        name = "check-option-schema";
        runtimeInputs = [ pkgs.python3 ];
        text = ''
          bash scripts/check-option-schema.sh
        '';
      };

      # Rejects ES6+ syntax in the inline <script> blocks of the statically
      # served landing pages under hosts/*/html/.
      #
      # Those pages are deliberately ES5: they exist to be usable during a
      # DNS/AdGuard outage on whatever browser is to hand, and a syntax
      # error there costs the WHOLE <script> element at parse time rather
      # than just the feature that used the new construct.
      #
      # The reason this is mechanised rather than left as a comment is that
      # the other formatter in this repo actively reintroduces the problem:
      # `prettier` runs on these files and emits ES2017, so any call it
      # cannot fit in 80 columns gets split with a trailing comma in the
      # argument list. That happened while adding the repository-jump
      # script, to a line that had been written correctly by hand. See
      # scripts/check-page-scripts-es5.sh's header.
      pageScriptsEs5Check = pkgs.writeShellApplication {
        name = "check-page-scripts-es5";
        # Two parsers, deliberately. eslint pinned to `ecmaVersion: 5` is
        # the authoritative gate -- a real grammar, so it also rejects
        # generators, default parameters, destructuring and for...of, which
        # no hand-maintained blocklist would have covered. The esprima
        # token scan runs alongside it purely to name the construct, since
        # eslint reports the trailing-comma case as "Unexpected token )",
        # which blames the paren rather than the comma.
        #
        # A tokeniser either way, never a grep: `,)` occurs legitimately
        # inside string literals and comments on that page.
        runtimeInputs = [
          pkgs.eslint
          (pkgs.python3.withPackages (ps: [ ps.esprima ]))
        ];
        text = ''
          bash scripts/check-page-scripts-es5.sh "$@"
        '';
      };

      # Hermetic tests for the deploy guard shared by switch-preflight.sh and
      # colmena-apply-drifted.sh (scripts/lib/deploy-guard.sh): every
      # switch-vs-boot rule, the probe and scan scripts run against a fixture
      # /run + /proc tree, and the preflight's exit codes. A wrong answer
      # there is either a needless reboot or a frozen PID 1, so the rules are
      # tested rather than reviewed.
      deployGuardCheck = pkgs.writeShellApplication {
        name = "check-deploy-guard";
        runtimeInputs = [
          pkgs.jq
          pkgs.gawk
          pkgs.gnugrep
          pkgs.gnused
          pkgs.coreutils
        ];
        text = ''
          bash scripts/tests/deploy-guard-test.sh
        '';
      };

      # Validates opencode.jsonc: a structural check (offline, default --
      # unknown top-level keys and command entries missing `template`,
      # wired into both the hook and the standalone check below via
      # `--offline`) plus, when run by hand with no flag, full validation
      # against opencode's live JSON Schema over the network. See
      # scripts/check-opencode-jsonc.sh's header for why the live-schema
      # mode cannot be wired into either the hook or the flake check.
      opencodeJsoncCheck = pkgs.writeShellApplication {
        name = "check-opencode-jsonc";
        runtimeInputs = [
          (pkgs.python3.withPackages (ps: [ ps.json5 ]))
          pkgs.jq
          pkgs.check-jsonschema
        ];
        text = ''
          bash scripts/check-opencode-jsonc.sh "$@"
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

          baseHooks = base.hooks // excludeBinaries base.hooks;

          run = gitHooks.lib.${system}.run {
            src = self;
            inherit (base) excludes;

            hooks = baseHooks // {
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

              ci-pipeline-files-sync = {
                enable = true;
                name = "CI pipeline files force-all-hosts sync (2 locations)";
                entry = "${pkgs.lib.getExe ciPipelineFilesSync}";

                # Fires on the two workflow files plus every file either
                # workflow shells out to directly and scripts/impacted-hosts.sh
                # itself, since the checker cross-references all of these
                # against the FORCE_ALL_FILES arrays in that script.
                files = "^(\\.github/workflows/ci-(linux|darwin)\\.yaml|\\.github/merge-queue-ci-skipper/action\\.yaml|scripts/(attic-push|check-colmena-parity|diff-closures-comment|impacted-hosts)\\.sh)$";
                pass_filenames = false;
              };

              deploy-guard = {
                enable = true;
                name = "deploy guard tests (switch vs boot rules)";
                entry = "${pkgs.lib.getExe deployGuardCheck}";

                # The library, both scripts built on it, the tests, and the
                # Nix half of the facts they compare against.
                files = "^(scripts/(lib/deploy-guard|switch-preflight|colmena-apply-drifted|tests/deploy-guard-test)\\.sh|flake/lib/deploy-facts\\.nix)$";
                pass_filenames = false;
              };

              docker-pin-spacing = {
                enable = true;
                name = "docker image pins are not on adjacent lines";
                entry = "${pkgs.lib.getExe dockerPinSpacingCheck}";
                files = "^modules/data/docker-image-pins\\.nix$";
                pass_filenames = false;
              };

              sops-recipients = {
                enable = true;
                name = "sops age-recipient consistency (keys / creation_rules / secrets.yaml)";
                entry = "${pkgs.lib.getExe sopsRecipientsCheck}";

                # Fires when either the recipient/anchor declarations or the
                # ciphertext's own embedded recipient metadata change --
                # either side of the invariant can drift independently.
                files = "^modules/secrets/(\\.sops\\.yaml|secrets\\.yaml)$";
                pass_filenames = false;
              };

              doc-drift = {
                enable = true;
                name = "MODULES.md / desktop-server host-split drift";
                entry = "${pkgs.lib.getExe docDriftCheck}";

                # flake.nix is where the `nixosModules` attrset itself is
                # declared (module add/rename/removal), so it is the actual
                # trigger for MODULES.md drift, not modules/*.nix directly.
                files = "^(MODULES\\.md|flake\\.nix|flake/hosts/servers\\.nix|\\.github/workflows/ci-linux\\.yaml)$";
                pass_filenames = false;
              };

              module-reachability = {
                enable = true;
                name = "no orphaned .nix modules (dead-file reachability)";
                entry = "${pkgs.lib.getExe moduleReachabilityCheck}";

                # Any .nix file change can create or resolve an orphan --
                # adding a new file nobody imports yet, or deleting the last
                # import of an existing one -- so this always re-scans the
                # whole tree rather than reacting to a specific path.
                # pass_filenames is off for the same reason: a single-file
                # view cannot tell whether that file is reachable from
                # anywhere else.
                files = "\\.nix$";
                pass_filenames = false;
              };

              option-schema = {
                enable = true;
                name = "mkOption type + description coverage";
                entry = "${pkgs.lib.getExe optionSchemaCheck}";

                # Same reasoning as module-reachability: an mkOption call can
                # appear in any .nix file, so this re-scans the whole tree on
                # any .nix change rather than reacting to a specific path.
                files = "\\.nix$";
                pass_filenames = false;
              };

              page-scripts-es5 = {
                enable = true;
                name = "landing-page <script> blocks are ES5";
                entry = "${pkgs.lib.getExe pageScriptsEs5Check}";

                # git-hooks orders hooks alphabetically by attribute name, so
                # this runs BEFORE `prettier` -- which is the hook that
                # introduces the violation in the first place. That ordering
                # is not fixable without renaming the hook to sort after it,
                # and it does not need to be: prettier fails the commit
                # whenever it rewrites a file, so the sequence is
                #
                #   commit 1: prettier reformats, reports "files were
                #             modified", commit aborts
                #   commit 2: prettier is a no-op, this hook now reads the
                #             reformatted bytes and rejects the trailing
                #             comma
                #
                # The violation therefore cannot reach a commit, it just
                # takes the same two rounds any formatter/linter pair does.
                # The standalone `page-scripts-es5` check is the backstop for
                # anything that got in via --no-verify.
                #
                # pass_filenames is off because the script resolves its own
                # file set from hosts/*/html/*.html; a page can also be
                # broken by an edit to a sibling that git-hooks would not
                # have listed.
                files = "^hosts/.*/html/.*\\.html$";
                pass_filenames = false;
              };

              opencode-jsonc-schema = {
                enable = true;
                name = "opencode.jsonc schema validation (structural, offline)";
                entry = "${pkgs.lib.getExe opencodeJsoncCheck} --offline";

                # `--offline`, not the default network mode: git-hooks'
                # own `run` derivation (this is also what `nix build
                # .#checks.pre-commit-check` and CI's lint job exercise)
                # executes the WHOLE hook suite inside a sandboxed Nix
                # build with no network, regardless of whether a human
                # triggered it via `git commit` or via `nix flake check`.
                # A hook that needs network here doesn't just skip
                # gracefully -- it hard-fails the build for everyone. See
                # scripts/check-opencode-jsonc.sh's header for the full
                # reasoning and how to run the live-schema check manually.
                files = "^opencode\\.jsonc$";
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

      ci-pipeline-files-sync =
        pkgs.runCommand "ci-pipeline-files-sync-check"
          {
            nativeBuildInputs = [ ciPipelineFilesSync ];
          }
          ''
            cd ${self}
            check-ci-pipeline-files-sync
            touch "$out"
          '';

      # Standalone so `nix flake check` and CI run the guard tests even on a
      # route that never ran pre-commit hooks.
      deploy-guard =
        pkgs.runCommand "deploy-guard-check"
          {
            nativeBuildInputs = [ deployGuardCheck ];
          }
          ''
            cd ${self}
            check-deploy-guard
            touch "$out"
          '';

      # Standalone so CI catches collapsed spacing on Renovate PRs and web
      # edits, neither of which ever runs pre-commit hooks.
      docker-pin-spacing =
        pkgs.runCommand "docker-pin-spacing-check"
          {
            nativeBuildInputs = [ dockerPinSpacingCheck ];
          }
          ''
            cd ${self}
            check-docker-pin-spacing
            touch "$out"
          '';

      sops-recipients =
        pkgs.runCommand "sops-recipients-check"
          {
            nativeBuildInputs = [ sopsRecipientsCheck ];
          }
          ''
            cd ${self}
            check-sops-recipients
            touch "$out"
          '';

      # docDriftCheck already has ACTUAL_MODULES_JSON / ALL_SYSTEMS_JSON /
      # SERVERS_NIX_KEYS_JSON baked in at build time (see its definition
      # above), so this needs no extra wiring -- same derivation, same
      # hermetic values, as the pre-commit hook entry.
      doc-drift =
        pkgs.runCommand "doc-drift-check"
          {
            nativeBuildInputs = [ docDriftCheck ];
          }
          ''
            cd ${self}
            check-doc-drift
            touch "$out"
          '';

      # `--offline` skips the live-schema fetch: a sandboxed Nix build has
      # no network, so only the structural check (unknown top-level keys,
      # command entries missing `template`) runs here. Same reason the
      # pre-commit hook above passes `--offline` too -- see its comment.
      # Full schema validation is available by running
      # `scripts/check-opencode-jsonc.sh` (no flag) directly, by hand.
      opencode-jsonc-schema =
        pkgs.runCommand "opencode-jsonc-schema-check"
          {
            nativeBuildInputs = [ opencodeJsoncCheck ];
          }
          ''
            cd ${self}
            check-opencode-jsonc --offline
            touch "$out"
          '';

      # Standalone check so `nix flake check` and CI catch an orphaned
      # module even on a route that never ran pre-commit hooks.
      module-reachability =
        pkgs.runCommand "module-reachability-check"
          {
            nativeBuildInputs = [ moduleReachabilityCheck ];
          }
          ''
            cd ${self}
            check-module-reachability
            touch "$out"
          '';

      # Standalone check so `nix flake check` and CI catch an ES6 construct
      # in a landing page even on a route that never ran pre-commit hooks
      # -- which is the likely route, since the construct is usually
      # introduced BY a pre-commit hook (prettier) rather than by a human.
      page-scripts-es5 =
        pkgs.runCommand "page-scripts-es5-check"
          {
            nativeBuildInputs = [ pageScriptsEs5Check ];
          }
          ''
            cd ${self}
            check-page-scripts-es5
            touch "$out"
          '';

      # Standalone check so `nix flake check` and CI catch a schema
      # regression (a new mkOption with no type/description) even on a
      # route that never ran pre-commit hooks.
      option-schema =
        pkgs.runCommand "option-schema-check"
          {
            nativeBuildInputs = [ optionSchemaCheck ];
          }
          ''
            cd ${self}
            check-option-schema
            touch "$out"
          '';

      # Fails when nixpkgs moves sbomnix off the version our source
      # patch was verified against.
      #
      # The `sbomnix` overlay carries a patch against sbomnix internals
      # (overlays/default.nix, FIXME sbomnix-pinned-version-cpe-drop).
      # It is gated to an exact version, so a bump silently drops it
      # rather than failing to apply -- and the CVE scan would keep
      # running while quietly losing the CPEs of most core packages
      # (glibc, openssl, the kernel, ...), which reads as "clean" rather
      # than "broken". That happened for real at the 1.8.0 -> 1.9.0 bump,
      # so it must not be reintroduced by a routine flake update.
      #
      # cve-scan.yaml's scannable-component assertion is the runtime
      # backstop; this check is the eval-time one, so a bump is caught by
      # `nix flake check` in CI on the update PR instead of a week later
      # by the Monday scan.
      #
      # On a bump: re-verify the patch against the new sbomnix tree (it
      # touches builder.py and package_meta.py), refresh it if the
      # surrounding code moved, confirm a manual scan still reports a
      # healthy scannable-component count, then update
      # `sbomnixPatchedVersion` in overlays/default.nix. If upstream has
      # fixed the bug, drop the patch and close out its entry in
      # .github/tracked-upstream-fixes.json instead.
      sbomnix-patch-version =
        let
          overlayPkgs = import inputs.nixpkgs {
            inherit system;
            overlays = [ (import ../../overlays) ];
          };
          expected = overlayPkgs.sbomnixPatchedVersion;
          actual = overlayPkgs.sbomnix.version;
        in
        pkgs.runCommand "sbomnix-patch-version-check" { } (
          if actual == expected then
            ''
              echo "sbomnix ${actual} matches the patched version; overlay patch applies"
              touch "$out"
            ''
          else
            ''
              echo "sbomnix is ${actual}, but the overlay patch targets ${expected}." >&2
              echo "" >&2
              echo "The patch is version-gated, so it is NOT being applied." >&2
              echo "Left as-is the CVE scan still runs but silently loses the CPEs" >&2
              echo "of most core packages and reports them as clean." >&2
              echo "" >&2
              echo "Re-verify overlays/sbomnix-recover-pinned-version-cpes.patch" >&2
              echo "against the new tree, then set sbomnixPatchedVersion in" >&2
              echo "overlays/default.nix to ${actual}. If upstream fixed the bug," >&2
              echo "drop the patch and resolve its entry in" >&2
              echo ".github/tracked-upstream-fixes.json." >&2
              exit 1
            ''
        );
    }
  );
}
