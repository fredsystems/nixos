{
  lib,
  config,
  ...
}:

let
  cfg = config.programs.sync-compose;
in
{
  options.programs.sync-compose = {
    enable = lib.mkEnableOption "Compose sync helper";

    user = lib.mkOption {
      type = lib.types.str;
      default = config.home.username;
      description = "SSH username used for remote hosts.";
    };

    hosts = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              description = "Identifier of the host (e.g., sdrhub)";
            };
            ip = lib.mkOption {
              type = lib.types.str;
              description = "IP or hostname of the remote host.";
            };
            directory = lib.mkOption {
              type = lib.types.str;
              description = "Directory under ~/GitHub/adsb-compose/";
            };
            remotePath = lib.mkOption {
              type = lib.types.str;
              description = "Remote directory containing docker-compose.yml and .env";
            };
            port = lib.mkOption {
              type = lib.types.str;
              default = "22";
            };
            legacyScp = lib.mkOption {
              type = lib.types.bool;
              default = false;
            };
          };
        }
      );
      default = [ ];
    };
  };

  config = lib.mkIf cfg.enable {
    # Install the script into ~/.local/bin/sync-compose
    home.file."sync-compose" = {
      target = ".local/bin/sync-compose";
      executable = true;

      text = ''
        #!/usr/bin/env bash
        set -euo pipefail

        RED="\033[31m"; GRN="\033[32m"; YLW="\033[33m"
        BLU="\033[34m"; CYN="\033[36m"; RST="\033[0m"

        info() { echo -e "$BLU[INFO]$RST $*"; }
        ok()   { echo -e "$GRN[ OK ]$RST $*"; }
        err()  { echo -e "$RED[ERR ]$RST $*" >&2; exit 1; }

        BASE="$HOME/GitHub/adsb-compose"
        USER="${cfg.user}"

        DRYRUN=0
        if [[ "''${1:-}" == "--dry-run" ]]; then
          DRYRUN=1
          shift
        fi

        run() {
          if [[ "$DRYRUN" == 1 ]]; then
            echo "[DRY] $*"
          else
            eval "$*"
          fi
        }

        sync_local_to_remote() {
          local ip="$1" rpath="$2" dir="$3" port="$4" legacy="$5"
          local comp="$BASE/$dir/docker-compose.yaml"
          local envf="$BASE/$dir/.env"

          info "Validating compose"
          run docker compose -f "$comp" config --quiet

          local scpcmd="scp -P $port"
          [[ "$legacy" == "true" ]] && scpcmd="$scpcmd -O"

          info "Copy compose → remote"
          run "$scpcmd" "$comp" "$USER@$ip:$rpath/docker-compose.yaml"

          info "Copy env → remote"
          run "$scpcmd" "$envf" "$USER@$ip:$rpath/.env"

          ok "Sync complete for $dir"
        }

        sync_remote_to_local() {
          local ip="$1" rpath="$2" dir="$3" port="$4" legacy="$5"
          local comp="$BASE/$dir/docker-compose.yaml"
          local envf="$BASE/$dir/.env"

          local scpcmd="scp -P $port"
          [[ "$legacy" == "true" ]] && scpcmd="$scpcmd -O"

          info "Backing up"
          run mv "$comp" "$comp.bak"
          run mv "$envf" "$envf.bak"

          info "Copy compose ← remote"
          run "$scpcmd" "$USER@$ip:$rpath/docker-compose.yaml" "$comp"

          info "Copy env ← remote"
          run "$scpcmd" "$USER@$ip:$rpath/.env" "$envf"

          info "Validating compose"
          run docker compose -f "$comp" config --quiet

          ok "Sync complete for $dir"
        }

        direction="''${1:-}"; shift || err "Missing <local|remote>"
        target="''${1:-}"; shift || err "Missing target"

        case "$direction" in
          local|remote) ;;
          *) err "Direction must be: local | remote" ;;
        esac

        case "$target" in
      ''
      + lib.concatStringsSep "\n" (
        map (
          host:
          let
            port = host.port or "22";
            legacy = if (host.legacyScp or false) then "true" else "false";
          in
          ''
            ${host.name})
              if [[ "$direction" == "local" ]]; then
                sync_local_to_remote "${host.ip}" "${host.remotePath}" "${host.directory}" "${port}" "${legacy}"
              else
                sync_remote_to_local "${host.ip}" "${host.remotePath}" "${host.directory}" "${port}" "${legacy}"
              fi
              ;;
          ''
        ) cfg.hosts
      )

      + ''
          *)
            err "Unknown target: $target"
            ;;
        esac
      '';
    };
  };
}
