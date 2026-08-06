{
  lib,
  pkgs,
  config,
  isDarwin ? false,
  ...
}:

with lib;

let
  cfg = config.ci.githubRunners;
  hostname = config.networking.hostName;
  isLinux = !isDarwin;

  # Cleanup helper: delete runner by name before (re)registering.
  #
  # This runs as ExecStartPre, so ANY non-zero exit here fails the unit --
  # and upstream's restart policy does not cover that. nixpkgs sets
  # `Restart = if ephemeral then "on-success" else "no"` plus
  # `RestartForceExitStatus = [ 2 ]`, i.e. it restarts on a clean exit
  # (job finished, runner deregistered) and on the runner binary's own
  # retryable exit code 2. An ExecStartPre failure is neither, so the unit
  # lands in `failed` and stays there until someone intervenes.
  #
  # That is exactly what happened during the 2026-08-06 GitHub outage:
  #
  #   github-runner-cleanup: Deleting stale GitHub runner: ...-runner-3
  #   systemd: Control process exited, code=exited, status=22/n/a
  #   systemd: Failed with result 'exit-code'
  #
  # status 22 is curl's "HTTP error returned" from `-f`. The GitHub API
  # returned 5xx, `set -e` aborted, and the runner was dead for hours.
  #
  # Deleting a stale registration is best-effort housekeeping: if it fails,
  # the worst case is that registration later rejects a duplicate name and
  # the runner exits 2, which upstream DOES restart. So every API failure
  # here is a warning, never fatal. The script always exits 0.
  cleanupRunner = pkgs.writeShellScriptBin "github-runner-cleanup" ''
    set -uo pipefail

    RUNNER_NAME="$1"
    TOKEN_FILE="$2"
    REPO="$3"

    if ! TOKEN="$(cat "$TOKEN_FILE")"; then
      echo "WARNING: cannot read $TOKEN_FILE; skipping stale-runner cleanup" >&2
      exit 0
    fi

    # per_page=100 because the endpoint defaults to 30. fredhub alone now
    # registers 8 and the Mac Studio 4, and stale entries accumulate on top
    # of that, so a stale runner could land on page 2 and never be deleted --
    # after which re-registration fails on the duplicate name. 100 covers the
    # fleet with room to spare; full pagination would be ceremony for a
    # 12-runner estate.
    if ! RUNNER_LIST="$(
      ${pkgs.curl}/bin/curl -sf --max-time 30 \
        -H "Authorization: token $TOKEN" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$REPO/actions/runners?per_page=100"
    )"; then
      echo "WARNING: could not list runners (GitHub API unreachable or erroring);" \
           "skipping cleanup for $RUNNER_NAME" >&2
      exit 0
    fi

    RUNNER_ID="$(
      printf '%s' "$RUNNER_LIST" \
      | ${pkgs.jq}/bin/jq -r --arg NAME "$RUNNER_NAME" '
          .runners[] | select(.name == $NAME) | .id
        '
    )" || RUNNER_ID=""

    if [ -z "$RUNNER_ID" ]; then
      echo "No stale runner named $RUNNER_NAME"
      exit 0
    fi

    echo "Deleting stale GitHub runner: $RUNNER_NAME (id=$RUNNER_ID)"

    if ! ${pkgs.curl}/bin/curl -sf --max-time 30 -X DELETE \
      -H "Authorization: token $TOKEN" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/$REPO/actions/runners/$RUNNER_ID"; then
      echo "WARNING: failed to delete stale runner $RUNNER_NAME (id=$RUNNER_ID);" \
           "continuing -- registration will surface a genuine conflict as exit 2" >&2
    fi

    exit 0
  '';

  # Watchdog: restart github-runner units that are sitting in `failed`.
  #
  # Linux only, and deliberately a belt-and-braces measure rather than the
  # primary fix -- the primary fix is cleanupRunner above no longer failing
  # the unit on a GitHub API hiccup. This catches everything else that can
  # strand a runner outside upstream's restart policy (`on-success` plus
  # `RestartForceExitStatus = [ 2 ]`), including a tripped start-rate limit
  # (StartLimitBurst=5 within 10s), which leaves a unit failed permanently.
  #
  # Darwin needs no equivalent: launchd.daemons use `KeepAlive = true`,
  # which respawns unconditionally regardless of exit status, throttled to
  # one attempt per ThrottleInterval (30s).
  #
  # Restarts ONLY units in the failed state. An inactive-but-not-failed
  # runner is mid-cycle (ephemeral runners exit and are restarted between
  # jobs) and must not be touched.
  runnerWatchdog = pkgs.writeShellScriptBin "github-runner-watchdog" ''
    set -uo pipefail

    SELF="github-runner-watchdog.service"
    TEXTFILE_DIR=/var/lib/node_exporter/textfiles
    failed=0
    recovered=0

    units="$(
      ${pkgs.systemd}/bin/systemctl list-units --all --plain --no-legend \
        --type=service 'github-runner-*.service' 2>/dev/null \
      | ${pkgs.gawk}/bin/awk '{print $1}'
    )" || units=""

    for unit in $units; do
      # Never act on ourselves; that is how you write a restart loop.
      [ "$unit" = "$SELF" ] && continue

      ${pkgs.systemd}/bin/systemctl is-failed --quiet "$unit" || continue

      failed=$((failed + 1))
      echo "watchdog: $unit is in failed state; resetting and restarting"

      ${pkgs.systemd}/bin/systemctl reset-failed "$unit" || true

      if ${pkgs.systemd}/bin/systemctl start "$unit"; then
        recovered=$((recovered + 1))
        echo "watchdog: $unit restarted"
      else
        echo "watchdog: $unit FAILED to restart" >&2
      fi
    done

    if [ "$failed" -eq 0 ]; then
      echo "watchdog: no failed runner units"
    fi

    # Surface to prometheus. The alert rules key off the systemd collector's
    # node_systemd_unit_state rather than these, but "how often did the
    # watchdog have to intervene" is the signal that something is wrong
    # underneath, as opposed to a one-off blip.
    if [ -w "$TEXTFILE_DIR" ]; then
      tmp="$TEXTFILE_DIR/.github_runner_watchdog.prom.$$"
      {
        echo "# HELP github_runner_watchdog_failed_units Runner units found in failed state on the last watchdog sweep."
        echo "# TYPE github_runner_watchdog_failed_units gauge"
        echo "github_runner_watchdog_failed_units $failed"
        echo "# HELP github_runner_watchdog_recovered_units Runner units successfully restarted on the last watchdog sweep."
        echo "# TYPE github_runner_watchdog_recovered_units gauge"
        echo "github_runner_watchdog_recovered_units $recovered"
        echo "# HELP github_runner_watchdog_last_run_timestamp_seconds Unix time of the last watchdog sweep."
        echo "# TYPE github_runner_watchdog_last_run_timestamp_seconds gauge"
        echo "github_runner_watchdog_last_run_timestamp_seconds $(${pkgs.coreutils}/bin/date +%s)"
      } > "$tmp" && mv -f "$tmp" "$TEXTFILE_DIR/github_runner_watchdog.prom"
    fi

    exit 0
  '';

  # Darwin: wrapper script that does cleanup → configure → run for one runner.
  # Each runner gets its own working directory under /var/lib/github-runners/<name>.
  mkDarwinRunnerScript =
    runnerName: tokenFile: url: ephemeral:
    pkgs.writeShellScript "github-runner-${runnerName}" ''
      set -euo pipefail

      RUNNER_NAME="${runnerName}"
      TOKEN_FILE="${tokenFile}"
      REPO="${cfg.repo}"
      URL="${url}"
      WORK_DIR="/var/lib/github-runners/$RUNNER_NAME"

      # Ensure working directory exists
      mkdir -p "$WORK_DIR"
      export HOME="$WORK_DIR"

      # Wait for sops secret to be available (may not be decrypted yet at boot)
      for i in $(seq 1 60); do
        [ -f "$TOKEN_FILE" ] && [ -s "$TOKEN_FILE" ] && break
        echo "Waiting for token file ($i/60)..."
        sleep 5
      done

      if [ ! -f "$TOKEN_FILE" ] || [ ! -s "$TOKEN_FILE" ]; then
        echo "ERROR: Token file $TOKEN_FILE not available after 5 minutes" >&2
        exit 1
      fi

      # Cleanup stale registration
      ${cleanupRunner}/bin/github-runner-cleanup "$RUNNER_NAME" "$TOKEN_FILE" "$REPO"

      # Get a short-lived registration token from the GitHub API
      PAT="$(cat "$TOKEN_FILE")"
      REG_TOKEN="$(
        ${pkgs.curl}/bin/curl -sf -X POST \
          -H "Authorization: token $PAT" \
          -H "Accept: application/vnd.github+json" \
          "https://api.github.com/repos/$REPO/actions/runners/registration-token" \
        | ${pkgs.jq}/bin/jq -r '.token'
      )"

      if [ -z "$REG_TOKEN" ] || [ "$REG_TOKEN" = "null" ]; then
        echo "ERROR: Failed to obtain registration token" >&2
        exit 1
      fi

      cd "$WORK_DIR"

      # Force-clean all stale state so configure always starts fresh
      rm -rf "$WORK_DIR"/.runner "$WORK_DIR"/.credentials "$WORK_DIR"/.credentials_rsaparams "$WORK_DIR"/.github-runner

      # Configure the runner
      ${pkgs.github-runner}/bin/Runner.Listener configure \
        --unattended \
        --url "$URL" \
        --token "$REG_TOKEN" \
        --name "$RUNNER_NAME" \
        --labels "self-hosted,macOS,ARM64" \
        --work "$WORK_DIR/_work" \
        ${optionalString ephemeral "--ephemeral"} \
        --replace

      # Run the runner (blocks until job completes if ephemeral, or until stopped)
      exec ${pkgs.github-runner}/bin/Runner.Listener run
    '';

  # Construct a github-runners entry (shared logic for building the flat list)
  mkRunner =
    id: runnerCfg:
    let
      prefix = if isDarwin then "darwin" else "nixos";
      runnerName = if runnerCfg.name != null then runnerCfg.name else "${prefix}-${hostname}-${id}";

      tokenFile = if runnerCfg.tokenFile != null then runnerCfg.tokenFile else cfg.defaultTokenFile;

      url = if runnerCfg.url != null then runnerCfg.url else "https://github.com/${cfg.repo}";
    in
    {
      inherit id;
      value = {
        enable = true;
        name = runnerName;
        inherit url tokenFile;
        inherit (runnerCfg) ephemeral;
      };
    };

  runnersList = mapAttrsToList mkRunner cfg.runners;

  # Build the full list of all runners (auto-generated + custom)
  allRunners =
    let
      prefix = if isDarwin then "darwin" else "nixos";
      autoRunners = genList (i: {
        id = "runner-${toString (i + 1)}";
        name = "${prefix}-${hostname}-runner-${toString (i + 1)}";
        tokenFile = cfg.defaultTokenFile;
        url = "https://github.com/${cfg.repo}";
        ephemeral = true;
      }) cfg.runnerCount;

      customRunners = map (r: {
        inherit (r) id;
        inherit (r.value)
          name
          tokenFile
          url
          ephemeral
          ;
      }) runnersList;
    in
    autoRunners ++ customRunners;

in
{
  ###### OPTIONS ######

  options.ci.githubRunners = {
    enable = mkEnableOption "GitHub self-hosted runners with cleanup";

    repo = mkOption {
      type = types.str;
      example = "FredSystems/nixos";
      description = "GitHub repo (owner/name) runners are registered to.";
    };

    defaultTokenFile = mkOption {
      type = types.path;
      description = "Default GitHub token file path.";
    };

    runnerCount = mkOption {
      type = types.int;
      default = 0;
      description = "Number of auto-generated runners (runner-1, runner-2, etc.). Set to 0 to disable auto-generation.";
    };

    runners = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            name = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Explicit runner name (defaults to <platform>-<host>-<id>).";
            };

            url = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "GitHub repository URL override.";
            };

            tokenFile = mkOption {
              type = types.nullOr types.path;
              default = null;
              description = "Token file override for this runner.";
            };

            ephemeral = mkOption {
              type = types.bool;
              default = true;
              description = "Whether the runner is ephemeral.";
            };
          };
        }
      );
      default = { };
      description = "GitHub runners keyed by logical ID (e.g. runner-1).";
    };
  };

  ###### IMPLEMENTATION ######

  config = mkIf cfg.enable (
    {
      # ── Shared ────────────────────────────────────────────────────────
      environment.systemPackages = [
        pkgs.curl
        pkgs.jq
        pkgs.xz
      ];
    }

    # ── Linux (NixOS) ────────────────────────────────────────────────
    # Uses optionalAttrs (not mkIf) because systemd.services and
    # services.github-runners do not exist as options in nix-darwin.
    // optionalAttrs isLinux {
      # Generate services.github-runners entries
      services.github-runners = mkMerge [
        # Auto-generated runners based on runnerCount
        (listToAttrs (
          genList (i: {
            name = "runner-${toString (i + 1)}";
            value = {
              enable = true;
              url = "https://github.com/${cfg.repo}";
              name = "nixos-${hostname}-runner-${toString (i + 1)}";
              tokenFile = cfg.defaultTokenFile;
              ephemeral = true;
            };
          }) cfg.runnerCount
        ))

        # Custom runners from the runners attrset
        (listToAttrs (
          map (r: {
            name = r.id;
            inherit (r) value;
          }) runnersList
        ))
      ];

      # Inject cleanup logic into systemd units
      systemd.services =
        let
          # Auto-generated runner services
          autoRunnerServices = listToAttrs (
            genList (i: {
              name = "github-runner-runner-${toString (i + 1)}";
              value = {
                serviceConfig = {
                  ExecStartPre = lib.mkBefore [
                    "+${cleanupRunner}/bin/github-runner-cleanup nixos-${hostname}-runner-${toString (i + 1)} ${cfg.defaultTokenFile} ${cfg.repo}"
                  ];
                };
              };
            }) cfg.runnerCount
          );

          # Custom runner services
          customRunnerServices = foldl' (
            acc: r:
            let
              svcName = "github-runner-${r.id}";
              runnerName = r.value.name;
            in
            acc
            // {
              ${svcName} = {
                serviceConfig = {
                  ExecStartPre = lib.mkBefore [
                    "+${cleanupRunner}/bin/github-runner-cleanup ${runnerName} ${r.value.tokenFile} ${cfg.repo}"
                  ];
                };
              };
            }
          ) { } runnersList;
        in
        mkMerge [
          autoRunnerServices
          customRunnerServices
          {
            github-runner-watchdog = {
              description = "Restart GitHub Actions runners stuck in the failed state";
              serviceConfig = {
                Type = "oneshot";
                ExecStart = "${runnerWatchdog}/bin/github-runner-watchdog";
              };
            };
          }
        ];

      # Sweep every 15 minutes. The window matters for the alert rules: the
      # GitHubRunnerUnitFailed alert waits 20m precisely so it only fires
      # for a runner the watchdog has already had a chance to fix and
      # could not, rather than for every transient failure.
      systemd.timers.github-runner-watchdog = {
        description = "Periodic sweep for failed GitHub Actions runners";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          # Give the runners a chance to register before the first sweep.
          OnBootSec = "5m";
          OnUnitActiveSec = "15m";
          # Catch up after the host has been off, rather than waiting a
          # full interval.
          Persistent = true;
          RandomizedDelaySec = "30s";
        };
      };
    }

    # ── Darwin (launchd) ─────────────────────────────────────────────
    # Uses optionalAttrs (not mkIf) because launchd.daemons does not
    # exist as an option in NixOS.
    // optionalAttrs isDarwin {
      # Ensure the runner working directory exists
      system.activationScripts.postActivation.text =
        let
          mkDir = r: "mkdir -p /var/lib/github-runners/${r.name}";
        in
        concatStringsSep "\n" (map mkDir allRunners);

      launchd.daemons = listToAttrs (
        map (r: {
          name = "github-runner-${r.id}";
          value = {
            # The wrapper script handles everything: cleanup, configure, run
            script = toString (mkDarwinRunnerScript r.name r.tokenFile r.url r.ephemeral);

            serviceConfig = {
              # Run as root so we can read sops secret files and create
              # working directories.  The runner itself drops privileges
              # internally when executing workflow steps.
              UserName = "root";
              GroupName = "wheel";

              # Restart on exit (ephemeral runners exit after each job)
              KeepAlive = true;

              # Wait 30 seconds before restarting to avoid being throttled by launchd
              ThrottleInterval = 30;

              # Working directory
              WorkingDirectory = "/var/lib/github-runners/${r.name}";

              # Log files for debugging
              StandardOutPath = "/var/log/github-runner-${r.id}.out.log";
              StandardErrorPath = "/var/log/github-runner-${r.id}.err.log";

              # Ensure network is available before starting
              RunAtLoad = true;

              # Set PATH so the runner can find nix and other tools
              EnvironmentVariables = {
                PATH = concatStringsSep ":" [
                  "/run/current-system/sw/bin"
                  "/nix/var/nix/profiles/default/bin"
                  "/usr/local/bin"
                  "/usr/bin"
                  "/bin"
                  "/usr/sbin"
                  "/sbin"
                ];
                # Tell the runner where the Nix daemon socket is
                NIX_SSL_CERT_FILE = "/nix/var/nix/profiles/default/etc/ssl/certs/ca-bundle.crt";
                HOME = "/var/lib/github-runners/${r.name}";
              };
            };
          };
        }) allRunners
      );
    }
  );
}
