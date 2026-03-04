{
  lib,
  pkgs,
  config,
  ...
}:

with lib;

let
  cfg = config.ci.githubRunners;
  hostname = config.networking.hostName;

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

  # Construct a github-runners entry
  mkRunner =
    id: runnerCfg:
    let
      runnerName = if runnerCfg.name != null then runnerCfg.name else "nixos-${hostname}-${id}";

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
              description = "Explicit runner name (defaults to nixos-<host>-<id>).";
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

  config = mkIf cfg.enable {
    environment.systemPackages = [
      pkgs.curl
      pkgs.jq
    ];

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

    # Inject cleanup logic into systemd units (CORRECT UNIT NAMES)
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
  };
}
