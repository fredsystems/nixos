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

          # Bounded deliberately. `tailscale status` talks to tailscaled's local
          # API, which blocks if the daemon is wedged -- and an unbounded read
          # would hang this oneshot until systemd's start timeout killed it,
          # leaving the previous .prom in place and the metrics silently frozen
          # at their last values. Timing out instead falls through to
          # STATUS_OK=0, which is the honest report and is what
          # TailscaleBackendNotRunning and the expiry guards expect. Matches the
          # --max-time already used by the imageapi metric on fredvps.
          # --kill-after matters as much as the timeout itself: a plain `timeout`
          # sends TERM and then waits indefinitely for a process that ignores it,
          # which would leave the oneshot active and the previous .prom in place
          # -- the exact silently-frozen-metrics outcome the bound exists to
          # prevent. SIGKILL five seconds later guarantees the fall-through.
          STATUS=$(${pkgs.coreutils}/bin/timeout --kill-after=5 10 \
            "$TAILSCALE" status --json 2>/dev/null || echo "")

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
        # Every 5 minutes, paced by the backend-state metric rather than by
        # expiry.
        #
        # Expiry alone would be happy with an hourly run -- it moves on a scale
        # of months. But this unit also emits tailscale_backend_running, and
        # TailscaleBackendNotRunning claims to fire after 15 minutes. On an
        # hourly timer that claim was false: up to 65 minutes to write the 0,
        # plus the 15 minute `for`, is roughly 80 minutes before a node that has
        # dropped to NeedsLogin is reported. An alert whose stated window is five
        # times shorter than reality is worse than one with an honest longer
        # window.
        #
        # Raising the frequency of the whole unit rather than splitting
        # backend-state into a second service and timer: the work is a single
        # local API call against tailscaled, so there is nothing to gain by
        # collecting the two halves separately, and a second unit would be more
        # moving parts for the same result.
        OnCalendar = "*:0/5";
        Persistent = true;
        # Small relative to the interval; enough to keep the two tailnet hosts
        # off the same instant without eating into the detection window.
        RandomizedDelaySec = "30";
      };
    };
  };
}
