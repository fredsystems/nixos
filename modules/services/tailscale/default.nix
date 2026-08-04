{ config, pkgs, ... }:
{
  sops.secrets."tailscale/authkey" = {
    mode = "0400";
  };

  services.tailscale = {
    enable = true;
    authKeyFile = config.sops.secrets."tailscale/authkey".path;
    openFirewall = true;
  };

  # Node key expiry metric.
  #
  # WHAT ACTUALLY EXPIRES, AND WHY THIS IS NOT ABOUT THE SOPS AUTH KEY
  #
  # Two different Tailscale credentials are easy to conflate:
  #
  #   * The auth key above (tskey-auth-...). Used ONCE to register a device.
  #     `services.tailscale` only invokes it when the node is not already
  #     authenticated, so an expired auth key does not disturb a running node --
  #     it only blocks a fresh registration or a forced re-auth.
  #
  #   * Each device's NODE key, which has its own expiry and is the one that
  #     takes a working node off the tailnet. Rotating the sops auth key does not
  #     renew it; an expired node key needs `tailscale up` with an interactive
  #     login URL, or a new key plus --force-reauth.
  #
  # This metric watches the second one, because that is the failure that costs
  # something: on sdrhub it also withdraws the advertised 192.168.31.0/24 subnet
  # route, and on fredvps it removes the tailnet address Prometheus scrapes it by.
  #
  # Tagged devices have key expiry disabled by default, so on a correctly tagged
  # fleet KeyExpiry is absent and this reports `expiry_disabled`. That is the
  # healthy end state, and the alerts treat it as such rather than as missing
  # data -- otherwise doing the right thing upstream would look like a fault.
  systemd = {
    services.tailscale-expiry-metric = {
      description = "Emit Tailscale node key expiry metrics";
      after = [ "tailscaled.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "tailscale-expiry-metric.sh" ''
          set -uo pipefail

          TAILSCALE=${config.services.tailscale.package}/bin/tailscale
          JQ=${pkgs.jq}/bin/jq

          HOST="${config.networking.hostName}"
          TEXTFILE_DIR=/var/lib/node_exporter/textfiles
          OUT="$TEXTFILE_DIR/tailscale_expiry.prom"

          mkdir -p "$TEXTFILE_DIR"

          EXPIRY=0
          EXPIRY_DISABLED=0
          EXPIRED=0
          RUNNING=0
          STATUS_OK=0

          STATUS=$("$TAILSCALE" status --json 2>/dev/null || echo "")

          if [[ -n "$STATUS" ]] && $JQ -e . <<<"$STATUS" >/dev/null 2>&1; then
            STATUS_OK=1

            [[ "$($JQ -r '.BackendState // ""' <<<"$STATUS")" == "Running" ]] && RUNNING=1
            [[ "$($JQ -r '.Self.Expired // false' <<<"$STATUS")" == "true" ]] && EXPIRED=1

            RAW=$($JQ -r '.Self.KeyExpiry // ""' <<<"$STATUS")
            if [[ -n "$RAW" && "$RAW" != "null" ]]; then
              PARSED=$(date -d "$RAW" +%s 2>/dev/null || echo "")
              [[ "$PARSED" =~ ^[0-9]+$ ]] && EXPIRY=$PARSED
            else
              # No expiry reported: key expiry is disabled for this device, which
              # is the desired configuration for an always-on server.
              EXPIRY_DISABLED=1
            fi
          fi

          TMP="$OUT.tmp"
          {
            echo "# HELP tailscale_key_expiry_seconds Unix time this node's Tailscale node key expires (0 if none)."
            echo "# TYPE tailscale_key_expiry_seconds gauge"
            echo "tailscale_key_expiry_seconds{host=\"$HOST\"} $EXPIRY"

            echo "# HELP tailscale_key_expiry_disabled Whether key expiry is disabled for this node."
            echo "# TYPE tailscale_key_expiry_disabled gauge"
            echo "tailscale_key_expiry_disabled{host=\"$HOST\"} $EXPIRY_DISABLED"

            echo "# HELP tailscale_node_expired Whether this node's key has already expired."
            echo "# TYPE tailscale_node_expired gauge"
            echo "tailscale_node_expired{host=\"$HOST\"} $EXPIRED"

            echo "# HELP tailscale_backend_running Whether tailscaled reports BackendState=Running."
            echo "# TYPE tailscale_backend_running gauge"
            echo "tailscale_backend_running{host=\"$HOST\"} $RUNNING"

            # Emitted unconditionally so the expiry alerts can require a
            # successful status read. Without it, a tailscaled that will not
            # answer leaves expiry at 0, which reads as "expires at the epoch"
            # and would fire the expiry alerts for what is really a daemon fault.
            echo "# HELP tailscale_status_scrape_success Whether tailscale status --json was read successfully."
            echo "# TYPE tailscale_status_scrape_success gauge"
            echo "tailscale_status_scrape_success{host=\"$HOST\"} $STATUS_OK"
          } > "$TMP"
          mv "$TMP" "$OUT"
        '';
      };
    };

    timers.tailscale-expiry-metric = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # Expiry moves on a scale of months; hourly is ample and keeps the series
        # responsive enough to notice tailscaled dying.
        OnCalendar = "hourly";
        Persistent = true;
        RandomizedDelaySec = "300";
      };
    };
  };
}
