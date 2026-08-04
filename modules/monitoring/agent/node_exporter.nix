{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:
{
  systemd = {
    services = {
      nixos-needs-reboot-metric = {
        description = "Emit reboot-needed metric for Prometheus";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = pkgs.writeShellScript "nixos-needs-reboot-metric.sh" ''
            # Run nixos-needsreboot to create/update the /run/reboot-required sentinel
            ${
              inputs.nixos-needsreboot.packages.${config.nixpkgs.hostPlatform.system}.default
            }/bin/nixos-needsreboot || true

            NEEDS_REBOOT=0

            if [ -e /run/reboot-required ]; then
              NEEDS_REBOOT=1
            fi

            mkdir -p /var/lib/node_exporter/textfiles

            echo "nixos_needs_reboot{host=\"${config.networking.hostName}\"} $NEEDS_REBOOT" \
              > /var/lib/node_exporter/textfiles/nixos_needs_reboot.prom
          '';
        };
      };

      # Deploy state relative to the fleet manifest published by
      # .github/workflows/fleet-manifest.yaml.
      #
      # This replaces three earlier services (nixos-branch-metric,
      # nixos-build-info-metric, nixos-revision-metric), all of which keyed off
      # a git SHA written to /etc/nixos/configuration-revision and asked the
      # GitHub compare API for a commit distance. That produced three distinct
      # classes of false alert:
      #
      #   * A commit that moved main without changing THIS host's closure still
      #     counted, so every host alerted on every unrelated commit and the
      #     "fix" was a rebuild that changed nothing. Commit distance simply is
      #     not a measure of whether a host needs a deploy.
      #   * A dirty or branch build recorded the literal string "dirty", and the
      #     script then hard-coded BEHIND=0 for that case -- so a host built
      #     from a WIP tree reported healthy no matter how far main moved. The
      #     one situation most deserving an alert was the one that silenced it.
      #   * The SHA was written from a system.activationScripts entry, which is
      #     part of system.build.toplevel. Every commit therefore changed every
      #     host's store path, poisoning the only exact signal available. See
      #     the note in flake/lib/mk-system.nix.
      #
      # The manifest records the toplevel store path main expects per host, so
      # the comparison here is exact: identical paths means identical systems,
      # and a commit that does not alter this host's closure cannot move it.
      nixos-deploy-state-metric = {
        description = "Emit NixOS deploy state metrics from the fleet manifest";
        # Needs the network to refresh the manifest. It degrades to the cached
        # copy rather than failing, but ordering after the network avoids a
        # guaranteed-failing fetch on every boot.
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          StateDirectory = "nixos-deploy-state";
          ExecStart = pkgs.writeShellScript "nixos-deploy-state-metric.sh" ''
            set -uo pipefail

            CURL=${pkgs.curl}/bin/curl
            JQ=${pkgs.jq}/bin/jq

            HOST="${config.networking.hostName}"
            MANIFEST_URL="https://raw.githubusercontent.com/fredsystems/nixos/fleet-manifest/manifest.json"

            STATE_DIR=/var/lib/nixos-deploy-state
            CACHE="$STATE_DIR/manifest.json"
            TEXTFILE_DIR=/var/lib/node_exporter/textfiles
            OUT="$TEXTFILE_DIR/nixos_deploy_state.prom"

            mkdir -p "$STATE_DIR" "$TEXTFILE_DIR"

            RUNNING=$(readlink -f /run/current-system 2>/dev/null || echo "")

            # Refresh the manifest into a temp file first: a truncated or
            # error-page response must not clobber a good cached copy, or a
            # transient GitHub failure would flip the whole fleet to unknown.
            FETCH_OK=0
            TMP="$CACHE.tmp"
            if $CURL -sfL --max-time 30 -o "$TMP" "$MANIFEST_URL" \
              && $JQ -e '.schema == 1 and (.hosts | type == "object")' "$TMP" >/dev/null 2>&1; then
              mv "$TMP" "$CACHE"
              FETCH_OK=1
            else
              rm -f "$TMP"
            fi

            STATE="unknown"
            EXPECTED=""
            EXPECTED_REV=""
            CHANGED_AT=0
            GENERATED_AT=0

            if [[ -s "$CACHE" ]]; then
              GENERATED_AT=$($JQ -r '.generated_at // 0' "$CACHE" 2>/dev/null || echo 0)
              # history is newest-first and history[0] is the currently
              # expected closure; see scripts/gen-fleet-manifest.sh.
              EXPECTED=$($JQ -r --arg h "$HOST" '.hosts[$h].history[0].toplevel // ""' "$CACHE" 2>/dev/null || echo "")
              EXPECTED_REV=$($JQ -r --arg h "$HOST" '.hosts[$h].history[0].rev // ""' "$CACHE" 2>/dev/null || echo "")
              CHANGED_AT=$($JQ -r --arg h "$HOST" '.hosts[$h].history[0].at // 0' "$CACHE" 2>/dev/null || echo 0)
            fi

            if [[ -n "$RUNNING" && -n "$EXPECTED" ]]; then
              if [[ "$RUNNING" == "$EXPECTED" ]]; then
                STATE="up_to_date"
              elif $JQ -e --arg h "$HOST" --arg p "$RUNNING" \
                '[.hosts[$h].history[].toplevel] | index($p) != null' "$CACHE" >/dev/null 2>&1; then
                # A closure main published previously: genuinely a deploy behind.
                STATE="drifted"
              else
                # Never published by main -- a local, dirty or branch build.
                # Distinguishing this from "drifted" is the whole point: the old
                # script reported it as healthy.
                STATE="unmanaged"
              fi
            fi

            # Revision the running closure came from, recovered by reverse
            # lookup now that the SHA is deliberately not baked into the system.
            RUNNING_REV=""
            if [[ -s "$CACHE" && -n "$RUNNING" ]]; then
              RUNNING_REV=$($JQ -r --arg h "$HOST" --arg p "$RUNNING" \
                'first(.hosts[$h].history[] | select(.toplevel == $p) | .rev) // ""' \
                "$CACHE" 2>/dev/null || echo "")
            fi

            # Deploy timestamp, read straight off the system profile symlink.
            #
            # /nix/var/nix/profiles/system is atomically replaced on every
            # activation that sets a new generation -- by nixos-rebuild switch and
            # by colmena apply alike -- so its own mtime IS the deploy time. It
            # needs no state file, is correct on the very first run, and survives
            # both a wiped StateDirectory and a reboot.
            #
            # An earlier version tracked this in state: it recorded the running
            # closure and stamped the clock whenever that changed, seeding from
            # the superseded metric's file on first run to avoid every host
            # reporting "deployed just now" at once. That reasoning was wrong.
            # This unit's first run can only ever happen on a closure that was
            # just activated, because installing the unit requires activating
            # one -- so "just now" was the correct answer, and seeding replaced it
            # with the host's PREVIOUS deploy time. Every host in the fleet
            # reported a deploy several hours older than the one that had just
            # happened, and the value then froze there until the next real deploy
            # because the legacy file it seeded from was deleted on the same run.
            #
            # /run/current-system is deliberately NOT used for this: it lives on
            # tmpfs and is recreated at boot, so its mtime is the last boot time
            # rather than the last deploy.
            DEPLOY_TS=$(stat -c %Y /nix/var/nix/profiles/system 2>/dev/null || echo 0)
            if [[ ! "$DEPLOY_TS" =~ ^[0-9]+$ ]]; then
              DEPLOY_TS=0
            fi

            # Retire the state and textfiles the superseded services left behind.
            rm -f /var/lib/node_exporter/textfiles/nixos_build_timestamp.val \
                  /var/lib/node_exporter/textfiles/nixos_build_last_sha \
                  "$STATE_DIR/deploy_timestamp_seconds" \
                  "$STATE_DIR/deploy_timestamp_ms" \
                  "$STATE_DIR/last_toplevel"

            MANIFEST_AGE=0
            if [[ "$GENERATED_AT" -gt 0 ]]; then
              MANIFEST_AGE=$(( $(date +%s) - GENERATED_AT ))
              [[ "$MANIFEST_AGE" -lt 0 ]] && MANIFEST_AGE=0
            fi

            # Store paths are safe as label values (no quotes, backslashes or
            # newlines are possible in a /nix/store path), so no escaping is
            # needed here. Basenames only: the /nix/store prefix is noise in a
            # dashboard and the hash is what identifies the closure.
            TMP_OUT="$OUT.tmp"
            {
              echo "# HELP nixos_deploy_state Deploy state vs the fleet manifest (1 on the active state)."
              echo "# TYPE nixos_deploy_state gauge"
              # Every state is emitted on every run, including the zeros. An
              # alert must never depend on a series being absent: absence is
              # indistinguishable from a broken exporter, and scripts/
              # check-alert-metrics.sh exists precisely because a rule matching
              # nothing is reported healthy.
              for s in up_to_date drifted unmanaged unknown; do
                if [[ "$s" == "$STATE" ]]; then v=1; else v=0; fi
                echo "nixos_deploy_state{host=\"$HOST\",state=\"$s\"} $v"
              done

              echo "# HELP nixos_expected_change_timestamp_seconds Unix time main last changed this host's expected closure."
              echo "# TYPE nixos_expected_change_timestamp_seconds gauge"
              echo "nixos_expected_change_timestamp_seconds{host=\"$HOST\"} $CHANGED_AT"

              # Value is always 1: this is an identity/"info" metric whose
              # payload is its labels. Keeping the value at 1 is what lets the
              # NixOSDeployDrift rule pull these labels into its annotations
              # with `* on (host) group_left (...)` without the join altering
              # the alert expression's value.
              echo "# HELP nixos_deploy_info Running and expected closure identity for this host."
              echo "# TYPE nixos_deploy_info gauge"
              echo "nixos_deploy_info{host=\"$HOST\",running=\"$(basename "$RUNNING")\",expected=\"$(basename "$EXPECTED")\",rev=\"$RUNNING_REV\",short_rev=\"''${RUNNING_REV:0:7}\",expected_rev=\"$EXPECTED_REV\",short_expected_rev=\"''${EXPECTED_REV:0:7}\"} 1"

              echo "# HELP nixos_deploy_timestamp_seconds Unix time this host's running closure last changed."
              echo "# TYPE nixos_deploy_timestamp_seconds gauge"
              echo "nixos_deploy_timestamp_seconds{host=\"$HOST\"} $DEPLOY_TS"

              echo "# HELP nixos_manifest_age_seconds Age of the fleet manifest this host compared against."
              echo "# TYPE nixos_manifest_age_seconds gauge"
              echo "nixos_manifest_age_seconds{host=\"$HOST\"} $MANIFEST_AGE"

              echo "# HELP nixos_manifest_fetch_success Whether the last manifest refresh succeeded."
              echo "# TYPE nixos_manifest_fetch_success gauge"
              echo "nixos_manifest_fetch_success{host=\"$HOST\"} $FETCH_OK"
            } > "$TMP_OUT"
            mv "$TMP_OUT" "$OUT"

            # Retire the files written by the three superseded services so a
            # stale .prom does not keep re-exporting removed metrics forever.
            # The textfile collector has no concept of expiry: whatever is in
            # the directory is exported until the file is deleted.
            rm -f "$TEXTFILE_DIR/nixos_branch.prom" \
                  "$TEXTFILE_DIR/nixos_build_info.prom" \
                  "$TEXTFILE_DIR/nixos_revision.prom"

            # Also retire the baked-in revision file itself. Nothing reads it
            # any more, and leaving it behind invites someone to trust a value
            # that is now frozen at whatever commit last deployed with the old
            # activation script. Cleaning it up from here rather than from a new
            # system.activationScripts entry is deliberate: the point of this
            # change was getting rev-bearing state out of the closure, and a
            # cleanup activation script would be a confusing thing to find
            # there next to the comment forbidding exactly that.
            rm -f /etc/nixos/configuration-revision
          '';
        };
      };
    }
    // lib.optionalAttrs config.services.fwupd.enable {
      fwupd-updates-metric = {
        description = "Emit fwupd available-firmware-updates metrics";
        # Ordering only — `after=` does NOT trigger fwupd-refresh. We rely on
        # the upstream fwupd-refresh.timer (daily, persistent) to keep LVFS
        # metadata current; this service simply consumes whatever metadata
        # exists on disk when it fires (every 30 minutes).
        after = [ "fwupd-refresh.service" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = pkgs.writeShellScript "fwupd-updates-metric.sh" ''
            set -u
            FWUPDMGR=${config.services.fwupd.package}/bin/fwupdmgr
            JQ=${pkgs.jq}/bin/jq
            HOST="${config.networking.hostName}"
            OUT=/var/lib/node_exporter/textfiles/fwupd_updates.prom
            TMP="$OUT.tmp"

            mkdir -p /var/lib/node_exporter/textfiles

            # fwupdmgr exits non-zero when there are no updates AND when
            # something goes wrong. Capture stdout regardless and fall back
            # to an empty device list so the script always emits valid
            # metrics for prometheus textfile collector consumption.
            JSON=$("$FWUPDMGR" get-updates --json 2>/dev/null || echo '{"Devices":[]}')

            # Validate JSON; treat malformed output as "no updates".
            if ! echo "$JSON" | "$JQ" -e . >/dev/null 2>&1; then
              JSON='{"Devices":[]}'
            fi

            COUNT=$(echo "$JSON" | "$JQ" '[.Devices[]?.Releases[0]?] | map(select(. != null)) | length')

            {
              echo "# HELP fwupd_updates_available Total firmware updates available on this host."
              echo "# TYPE fwupd_updates_available gauge"
              echo "fwupd_updates_available{host=\"$HOST\"} $COUNT"
              echo "# HELP fwupd_device_update_info Per-device firmware update info (value is always 1; metadata in labels)."
              echo "# TYPE fwupd_device_update_info gauge"
              # Prometheus exposition format requires label values to escape
              # backslash, double-quote, and newline. Order matters: escape
              # backslashes first or you'll double-escape the ones added by
              # the quote/newline steps.
              echo "$JSON" | "$JQ" -r --arg host "$HOST" '
                def promesc:
                  tostring
                  | gsub("\\\\"; "\\\\")
                  | gsub("\""; "\\\"")
                  | gsub("\n"; "\\n");
                .Devices[]?
                | select(.Releases[0]? != null)
                | . as $d
                | .Releases[0] as $r
                | "fwupd_device_update_info{host=\"\($host | promesc)\",device=\"\(($d.Name // "unknown") | promesc)\",vendor=\"\(($d.Vendor // "unknown") | promesc)\",version_current=\"\(($d.Version // "") | promesc)\",version_available=\"\(($r.Version // "") | promesc)\",urgency=\"\(($r.Urgency // "unknown") | ascii_downcase | promesc)\"} 1"
              '
            } > "$TMP"
            mv "$TMP" "$OUT"
          '';
        };
      };
    };

    timers = {
      nixos-needs-reboot-metric = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "*:0/10"; # run every 10 minutes
        };
      };

      nixos-deploy-state-metric = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          # Every 10 minutes. One conditional-GET-friendly fetch of a small
          # JSON file per host; raw.githubusercontent.com serves it from a CDN,
          # so this is far cheaper than the two unauthenticated api.github.com
          # calls per host per run that this replaces (those were also subject
          # to a 60/hour/IP rate limit the whole fleet shared behind one NAT).
          OnCalendar = "*:0/10";
          Persistent = true;
          # Without this the whole fleet fetches on the same wall-clock minute.
          RandomizedDelaySec = "120";
        };
      };
    }
    // lib.optionalAttrs config.services.fwupd.enable {
      fwupd-updates-metric = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "*:0/30"; # every 30 minutes — firmware changes infrequently
          Persistent = true;
        };
      };
    };
  };

  services = {
    #########################################################
    # Node Exporter
    #########################################################
    prometheus.exporters.node = {
      enable = true;
      openFirewall = true;
      listenAddress = "0.0.0.0";
      port = 9100;

      enabledCollectors = [
        "cpu"
        "meminfo"
        "diskstats"
        "filesystem"
        "loadavg"
        "netdev"
        "systemd"
        "textfile"
      ];

      extraFlags = [
        "--collector.textfile.directory=/var/lib/node_exporter/textfiles"

        # The systemd collector does not emit node_systemd_service_restart_total
        # unless this is set. Without it the DockerUnitFlapping alert selects
        # a metric that does not exist and silently never fires.
        "--collector.systemd.enable-restarts-metrics"
      ];
    };
  };

  networking.firewall.allowedTCPPorts = [
    9100 # node_exporter
  ];
}
