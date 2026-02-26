{ config, pkgs, ... }:
{
  systemd = {
    services = {
      nixos-branch-metric = {
        description = "Emit NixOS branch metric";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = pkgs.writeShellScript "nixos-branch-metric.sh" ''
            GIT=${pkgs.git}/bin/git
            REPO_DIR="/home/fred/GitHub/nixos"

            # If the repo doesn't exist on this node, emit no metric at all
            # (appliance nodes like SDR hubs don't have a local checkout)
            if [ ! -d "$REPO_DIR/.git" ]; then
              rm -f /var/lib/node_exporter/textfiles/nixos_branch.prom
              exit 0
            fi

            # Allow root to read a repo owned by fred
            export GIT_CONFIG_COUNT=1
            export GIT_CONFIG_KEY_0=safe.directory
            export GIT_CONFIG_VALUE_0="$REPO_DIR"

            branch=$($GIT -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)

            if [ "$branch" = "main" ]; then
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
            GIT=${pkgs.git}/bin/git

            REPO_DIR="/home/fred/GitHub/nixos"
            OWNER="fredsystems"
            REPO="nixos"
            HOST="${config.networking.hostName}"

            # --- Force Git to treat the repo as safe ---
            export GIT_CONFIG_COUNT=1
            export GIT_CONFIG_KEY_0=safe.directory
            export GIT_CONFIG_VALUE_0="$REPO_DIR"

            # --- Local commit (current checkout used for this system) ---
            LOCAL=$($GIT -C "$REPO_DIR" rev-parse HEAD)

            # --- Remote commit SHA from GitHub (main) ---
            API_COMMIT="https://api.github.com/repos/$OWNER/$REPO/commits/main"
            REMOTE=$($CURL -s "$API_COMMIT" | $JQ -r .sha)

            if [[ "$REMOTE" = "null" || -z "$REMOTE" ]]; then
                BEHIND=0
                LAG=0
            else
                # Compare REMOTE (base) ... LOCAL (head)
                # ahead_by  = commits LOCAL has that REMOTE doesn't (local ahead)
                # behind_by = commits REMOTE has that LOCAL doesn't (local behind)
                API_COMPARE="https://api.github.com/repos/$OWNER/$REPO/compare/$REMOTE...$LOCAL"
                COMPARE=$($CURL -s "$API_COMPARE")

                STATUS=$(echo "$COMPARE" | $JQ -r .status)
                BEHIND_BY=$(echo "$COMPARE" | $JQ -r .behind_by)
                AHEAD_BY=$(echo "$COMPARE" | $JQ -r .ahead_by)

                # Default safe values
                BEHIND=0
                LAG=0

                # If we actually got numbers, interpret them
                if [[ "$BEHIND_BY" != "null" && "$BEHIND_BY" =~ ^[0-9]+$ ]]; then
                    if [[ "$BEHIND_BY" -gt 0 ]]; then
                        # Local is behind remote
                        BEHIND=1
                        LAG=$BEHIND_BY
                    else
                        # Not behind; could be identical or ahead
                        BEHIND=0
                        LAG=0
                    fi
                fi
            fi

            mkdir -p /var/lib/node_exporter/textfiles

            cat <<EOF > /var/lib/node_exporter/textfiles/nixos_revision.prom
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
