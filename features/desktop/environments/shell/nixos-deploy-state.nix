{
  lib,
  pkgs,
  ...
}:
let
  # ── NixOS deploy state indicator ──────────────────────────────────────
  # Reports whether THIS MACHINE is running the closure main expects for it.
  #
  # This used to compare the local git checkout against its upstream and
  # report "behind by N commits", which was wrong in both directions:
  #
  #   1. False clean. `git pull` with no deploy made the widget go quiet
  #      while the machine carried on running the old generation. The thing
  #      being measured was the checkout, not the system.
  #   2. False dirty. Any commit touching only servers put every desktop
  #      into "behind by N", so the indicator was lit most of the time and
  #      therefore ignored.
  #
  # Both fall out of measuring the wrong object. The right one already
  # exists: nixos-deploy-state-metric.service (modules/monitoring/agent/
  # node_exporter.nix) compares `readlink -f /run/current-system` against
  # the per-host expected closure in the fleet manifest published by
  # .github/workflows/fleet-manifest.yaml. That is per-host, so a
  # server-only commit is correctly invisible here, and it is keyed on what
  # is actually activated, so pulling without deploying still reads as
  # drifted.
  #
  # This widget deliberately does NOT reimplement that comparison -- it
  # reads the .prom the service already emits (world-readable 0644,
  # refreshed every 10 minutes). One state machine, one place to be wrong.
  # It also means the widget does no network I/O at all, so the git fetch
  # and its throttle stamp are gone.
  #
  # States, from that service: up_to_date | drifted | unmanaged | unknown.
  #
  # Output is one JSON object per run: `alt` is the state key
  # (reboot | update | clean), `class` mirrors it for styling (reboot |
  # updates | clean), and `tooltip` is the human-readable state. Each shell
  # maps `alt` to its own icon.
  nixosStateProm = "/var/lib/node_exporter/textfiles/nixos_deploy_state.prom";
in
{
  options.desktop.environments.shell.nixosDeployState = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    description = "Script that reports this host's deploy state as JSON for a shell bar widget.";
    default = pkgs.writeShellApplication {
      name = "nixos-deploy-state";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.gnused
      ];
      text = ''
        prom="''${DEPLOY_STATE_PROM:-${nixosStateProm}}"

        # `text` is left empty: the shells render the state as an icon keyed
        # on `alt`, and the human-readable state lives in `tooltip`.
        emit() {
          # $1 = alt (icon key), $2 = class, $3 = tooltip
          printf '{"text":"","alt":"%s","class":"%s","tooltip":"%s"}\n' "$1" "$2" "$3"
        }

        # Pull a label out of the single nixos_deploy_info sample. The leading
        # [,{] anchors the match to a whole label name, so `short_rev` cannot
        # match inside `short_expected_rev`.
        info_label() {
          sed -n "s/^nixos_deploy_info{.*[,{]$1=\"\([^\"]*\)\".*/\1/p" "$prom" | head -1
        }

        gauge() {
          sed -n "s/^$1{[^}]*} \([0-9][0-9]*\).*/\1/p" "$prom" | head -1
        }

        human_age() {
          secs="$1"
          if [ "$secs" -lt 3600 ]; then
            printf '%dm' "$((secs / 60))"
          elif [ "$secs" -lt 86400 ]; then
            printf '%dh' "$((secs / 3600))"
          else
            printf '%dd' "$((secs / 86400))"
          fi
        }

        # 1. Reboot required (highest priority).
        if [ -f /run/reboot-required ]; then
          emit "reboot" "reboot" "Reboot required"
          exit 0
        fi

        # 2. No metrics. Deliberately NOT styled clean: the previous widget's
        #    worst failure mode was looking healthy while saying nothing
        #    meaningful, and "the exporter never ran" is exactly that.
        if [ ! -r "$prom" ]; then
          emit "update" "updates" "Deploy state unknown: nixos-deploy-state-metric has not produced metrics"
          exit 0
        fi

        state="$(sed -n 's/^nixos_deploy_state{[^}]*state="\([^"]*\)"} 1$/\1/p' "$prom" | head -1)"
        running_rev="$(info_label short_rev)"
        expected_rev="$(info_label short_expected_rev)"
        drifted_since="$(gauge nixos_drifted_since_seconds)"
        manifest_age="$(gauge nixos_manifest_age_seconds)"
        now="$(date +%s)"

        : "''${state:=}"
        : "''${drifted_since:=0}"
        : "''${manifest_age:=0}"

        # The service records the manifest's age at the moment it writes the
        # file. If the service stops running, the file and that age freeze,
        # and a stale "up to date" would read as clean forever. Age the value
        # by the time since the file was written so the guards below still
        # fire.
        written="$(stat -c %Y "$prom")"
        if [ "$now" -gt "$written" ]; then
          manifest_age=$((manifest_age + now - written))
        fi

        # A manifest nobody has refreshed in a day makes every verdict below
        # suspect, "up to date" included. Surface that rather than trust it.
        if [ "$manifest_age" -gt 86400 ]; then
          emit "update" "updates" "Fleet manifest is $(human_age "$manifest_age") old; deploy state cannot be trusted"
          exit 0
        fi

        case "$state" in
          drifted)
            behind=""
            if [ "$drifted_since" -gt 0 ] && [ "$now" -gt "$drifted_since" ]; then
              behind=" for $(human_age "$((now - drifted_since))")"
            fi
            emit "update" "updates" \
              "Deploy needed$behind: running ''${running_rev:-unknown}, main expects ''${expected_rev:-unknown}"
            ;;
          unmanaged)
            # Running something main never published: a local, dirty or
            # feature-branch build. Same remedy, different cause, so say which.
            emit "update" "updates" \
              "Running a closure main never published (local or branch build); deploy to return to main"
            ;;
          unknown)
            # The manifest predates the running closure, i.e. this host was
            # deployed more recently than the manifest was published.
            #
            # Normally that is a deploy racing the publisher and is not
            # actionable -- but a STUCK publisher produces the same state
            # indefinitely, so treating it as unconditionally clean would hide
            # a broken deploy-state pipeline behind the 24h guard above.
            #
            # fleet-manifest.yaml publishes every 6h and on every push to main,
            # so a manifest older than two cycles is not "catching up", it is
            # stuck. Below that, stay quiet; above it, say so.
            if [ "$manifest_age" -gt 43200 ]; then
              emit "update" "updates" \
                "Deploy state indeterminate: manifest is $(human_age "$manifest_age") old and predates the running closure"
            else
              emit "clean" "clean" "Deployed ahead of the published manifest; state will settle shortly"
            fi
            ;;
          up_to_date)
            emit "clean" "clean" "Running the closure main expects (''${running_rev:-unknown})"
            ;;
          *)
            emit "update" "updates" "Deploy state could not be read from the metrics file"
            ;;
        esac
      '';
    };
  };
}
