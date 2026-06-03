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
      nixos-branch-metric = {
        description = "Emit NixOS branch metric";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = pkgs.writeShellScript "nixos-branch-metric.sh" ''
            # For colmena-managed nodes there is no local git checkout.
            # A clean build from a known commit written to
            # /etc/nixos/configuration-revision is treated as "on main"
            # (value=1). A dirty build or missing file emits 0.
            REV=$(cat /etc/nixos/configuration-revision 2>/dev/null || echo "")

            if [[ -n "$REV" && "$REV" != "dirty" ]]; then
              value=1
            else
              value=0
            fi

            mkdir -p /var/lib/node_exporter/textfiles
            echo "nixos_branch{host=\"${config.networking.hostName}\"} $value" \
              > /var/lib/node_exporter/textfiles/nixos_branch.prom
          '';
        };
      };

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

      nixos-build-info-metric = {
        description = "Emit NixOS build SHA and deploy timestamp metrics";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = pkgs.writeShellScript "nixos-build-info-metric.sh" ''
            HOST="${config.networking.hostName}"
            SHA=$(cat /etc/nixos/configuration-revision 2>/dev/null || echo "dirty")
            TS_FILE="/var/lib/node_exporter/textfiles/nixos_build_timestamp.val"

            # Only update the timestamp when the SHA changes (i.e. a new deploy happened).
            # We persist the last-seen SHA alongside the timestamp so we can detect this.
            LAST_SHA_FILE="/var/lib/node_exporter/textfiles/nixos_build_last_sha"
            LAST_SHA=$(cat "$LAST_SHA_FILE" 2>/dev/null || echo "")

            mkdir -p /var/lib/node_exporter/textfiles

            if [[ "$SHA" != "dirty" && "$SHA" != "$LAST_SHA" ]]; then
              echo $(( $(date +%s) * 1000 )) > "$TS_FILE"
              echo "$SHA" > "$LAST_SHA_FILE"
            fi

            TS=$(cat "$TS_FILE" 2>/dev/null || echo "0")

            # Migrate existing values that were written as seconds (< 1e12) to milliseconds
            if [[ "$TS" -gt 0 && "$TS" -lt 1000000000000 ]]; then
              TS=$(( TS * 1000 ))
              echo "$TS" > "$TS_FILE"
            fi
            SHORT_SHA=''${SHA:0:7}

            cat > /var/lib/node_exporter/textfiles/nixos_build_info.prom <<EOF
            # HELP nixos_build_info NixOS build info: SHA label + deploy timestamp
            # TYPE nixos_build_info gauge
            nixos_build_info{host="$HOST", sha="$SHA", short_sha="$SHORT_SHA"} $TS
            EOF
          '';
        };
      };

      nixos-revision-metric = {
        description = "Emit NixOS upstream revision metrics";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = pkgs.writeShellScript "nixos-revision-metric.sh" ''
            set -euo pipefail

            CURL=${pkgs.curl}/bin/curl
            JQ=${pkgs.jq}/bin/jq

            OWNER="fredsystems"
            REPO="nixos"
            HOST="${config.networking.hostName}"

            # --- Revision this system was actually built and activated from.
            # Written persistently by the activationScript in mk-system.nix on
            # every colmena apply, so it survives reboots and never requires a
            # local git checkout on the node. ---
            LOCAL=$(cat /etc/nixos/configuration-revision 2>/dev/null || echo "")

            if [[ -z "$LOCAL" || "$LOCAL" = "dirty" ]]; then
                # No recorded revision (pre-activation or dirty build) — emit
                # zeroed metrics so the alert doesn't fire spuriously.
                BEHIND=0
                LAG=0
            else
                # --- Remote commit SHA from GitHub (main) ---
                API_COMMIT="https://api.github.com/repos/$OWNER/$REPO/commits/main"
                REMOTE=$($CURL -s "$API_COMMIT" | $JQ -r .sha)

                if [[ "$REMOTE" = "null" || -z "$REMOTE" ]]; then
                    # GitHub API unavailable — don't flip the alert
                    BEHIND=0
                    LAG=0
                else
                    # Compare LOCAL (base) ... REMOTE (head):
                    # ahead_by = commits REMOTE has that LOCAL doesn't
                    #            i.e. how many commits the running system is behind main
                    API_COMPARE="https://api.github.com/repos/$OWNER/$REPO/compare/$LOCAL...$REMOTE"
                    COMPARE=$($CURL -s "$API_COMPARE")

                    BEHIND_BY=$(echo "$COMPARE" | $JQ -r .ahead_by)

                    # Default safe values
                    BEHIND=0
                    LAG=0

                    if [[ "$BEHIND_BY" != "null" && "$BEHIND_BY" =~ ^[0-9]+$ ]]; then
                        if [[ "$BEHIND_BY" -gt 0 ]]; then
                            BEHIND=1
                            LAG=$BEHIND_BY
                        fi
                    fi
                fi
            fi

            mkdir -p /var/lib/node_exporter/textfiles

            cat > /var/lib/node_exporter/textfiles/nixos_revision.prom <<EOF
            nixos_revision_behind{host="$HOST"} $BEHIND
            nixos_revision_lag{host="$HOST"} $LAG
            EOF
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
      nixos-branch-metric = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "*:0/10"; # every 10 minutes
        };
      };

      nixos-needs-reboot-metric = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "*:0/10"; # run every 10 minutes
        };
      };

      nixos-build-info-metric = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "*:0/5"; # every 5 minutes — cheap, just reads a file
          Persistent = true;
        };
      };

      nixos-revision-metric = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "*:0/15"; # every 15 minutes
          Persistent = true;
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
      ];
    };
  };

  networking.firewall.allowedTCPPorts = [
    9100 # node_exporter
  ];
}
