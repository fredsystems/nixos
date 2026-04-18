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

  # Cleanup helper: delete runner by name before (re)registering
  cleanupRunner = pkgs.writeShellScriptBin "github-runner-cleanup" ''
    set -euo pipefail

    RUNNER_NAME="$1"
    TOKEN_FILE="$2"
    REPO="$3"

    TOKEN="$(cat "$TOKEN_FILE")"

    RUNNER_ID="$(
      ${pkgs.curl}/bin/curl -sf \
        -H "Authorization: token $TOKEN" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$REPO/actions/runners" \
      | ${pkgs.jq}/bin/jq -r --arg NAME "$RUNNER_NAME" '
          .runners[] | select(.name == $NAME) | .id
        '
    )"

    if [ -n "$RUNNER_ID" ]; then
      echo "Deleting stale GitHub runner: $RUNNER_NAME (id=$RUNNER_ID)"
      ${pkgs.curl}/bin/curl -sf -X DELETE \
        -H "Authorization: token $TOKEN" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$REPO/actions/runners/$RUNNER_ID"
    else
      echo "No stale runner named $RUNNER_NAME"
    fi
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

      # Remove any previous configuration
      if [ -f .runner ]; then
        ${pkgs.github-runner}/bin/Runner.Listener remove \
          --token "$REG_TOKEN" 2>/dev/null || true
      fi

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
        ];
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

              # Wait 5 seconds before restarting to avoid hammering the API
              ThrottleInterval = 5;

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
