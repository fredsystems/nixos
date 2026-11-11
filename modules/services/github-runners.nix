# modules/services/github-runners.nix
#
# OS-agnostic options and shared config for self-hosted GitHub Actions
# runners. The actual runner mechanism differs per platform -- NixOS's
# `services.github-runners` + systemd vs. launchd daemons on Darwin -- so
# that half lives in ./github-runners-linux.nix and ./github-runners-darwin.nix
# respectively. Every caller of this file must also import the half for its
# own OS; see those files' headers for the current caller list.
{
  lib,
  pkgs,
  config,
  ...
}:

let
  cfg = config.ci.githubRunners;
in
{
  ###### OPTIONS ######

  options.ci.githubRunners = {
    enable = lib.mkEnableOption "GitHub self-hosted runners with cleanup";

    repo = lib.mkOption {
      type = lib.types.str;
      example = "FredSystems/nixos";
      description = "GitHub repo (owner/name) runners are registered to.";
    };

    defaultTokenFile = lib.mkOption {
      type = lib.types.path;
      description = "Default GitHub token file path.";
    };

    runnerCount = lib.mkOption {
      type = lib.types.int;
      default = 0;
      description = "Number of auto-generated runners (runner-1, runner-2, etc.). Set to 0 to disable auto-generation.";
    };

    runners = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Explicit runner name (defaults to <platform>-<host>-<id>).";
            };

            url = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "GitHub repository URL override.";
            };

            tokenFile = lib.mkOption {
              type = lib.types.nullOr lib.types.path;
              default = null;
              description = "Token file override for this runner.";
            };

            ephemeral = lib.mkOption {
              type = lib.types.bool;
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

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      pkgs.curl
      pkgs.jq
      pkgs.xz
    ];
  };
}
