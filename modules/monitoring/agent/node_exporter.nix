{ config, pkgs, ... }:
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
                    # behind_by = commits REMOTE has that LOCAL doesn't
                    #             i.e. how many commits the running system is behind main
                    API_COMPARE="https://api.github.com/repos/$OWNER/$REPO/compare/$LOCAL...$REMOTE"
                    COMPARE=$($CURL -s "$API_COMPARE")

                    BEHIND_BY=$(echo "$COMPARE" | $JQ -r .behind_by)

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

      nixos-revision-metric = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "*:0/15"; # every 15 minutes
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
