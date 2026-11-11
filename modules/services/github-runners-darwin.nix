# modules/services/github-runners-darwin.nix
#
# Darwin half of ci.githubRunners: the module options and shared config live
# in ./github-runners.nix. This file wires launchd daemons directly (there is
# no nix-darwin equivalent of nixpkgs' `services.github-runners`); see
# ./github-runners-linux.nix for the NixOS equivalent.
#
# Callers (must also import ./github-runners.nix):
#   - hosts/darwin/Freds-Mac-Studio/configuration.nix
{
  lib,
  pkgs,
  config,
  ...
}:

let
  cfg = config.ci.githubRunners;
  hostname = config.networking.hostName;

  # Cleanup helper: delete runner by name before (re)registering. See
  # ./github-runners-linux.nix for the full rationale; identical on both
  # platforms, duplicated here because `isDarwin` no longer decides which
  # half of a shared `let` block to use.
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

  # Wrapper script that does cleanup → configure → run for one runner.
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
        ${lib.optionalString ephemeral "--ephemeral"} \
        --replace

      # Run the runner (blocks until job completes if ephemeral, or until stopped)
      exec ${pkgs.github-runner}/bin/Runner.Listener run
    '';

  # Construct a github-runners entry (shared logic for building the flat list)
  mkRunner =
    id: runnerCfg:
    let
      runnerName = if runnerCfg.name != null then runnerCfg.name else "darwin-${hostname}-${id}";

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

  runnersList = lib.mapAttrsToList mkRunner cfg.runners;

  # Build the full list of all runners (auto-generated + custom)
  allRunners =
    let
      autoRunners = lib.genList (i: {
        id = "runner-${toString (i + 1)}";
        name = "darwin-${hostname}-runner-${toString (i + 1)}";
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
  config = lib.mkIf cfg.enable {
    # Ensure the runner working directory exists
    system.activationScripts.postActivation.text =
      let
        mkDir = r: "mkdir -p /var/lib/github-runners/${r.name}";
      in
      lib.concatStringsSep "\n" (map mkDir allRunners);

    launchd.daemons = lib.listToAttrs (
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
              PATH = lib.concatStringsSep ":" [
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
  };
}
