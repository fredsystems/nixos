# Freshness metric for the imageapi (sdre-image-api) container on this host.
#
# WHY THIS IS NOT A BLACKBOX PROBE
#
# The blackbox exporter on sdrhub already probes
# https://fredclausen.com/imageapi/api/v1/last-updated and asserts it answers
# 2xx, which covers the whole public path: TLS, nginx, the proxy prefix strip,
# Express, and the database read behind that route. What it cannot do is look at
# the value: blackbox compares status codes and can regex a body, but it has no
# way to parse a timestamp and compute an age. A stuck updater returns a
# perfectly healthy 200 with a week-old timestamp.
#
# So availability lives in blackbox and freshness lives here. Splitting them also
# keeps the failure modes distinguishable -- a TLS or nginx fault trips the probe
# without implying the update loop is broken, and vice versa.
#
# WHY IT PROBES LOOPBACK
#
# The container's port is published on 127.0.0.1:3001 (see the imageapi entry in
# configuration.nix). Reading it directly makes this metric a statement about the
# service's own update loop rather than about the public edge, which the probe
# already watches. It also means a certificate or reverse-proxy problem cannot
# masquerade as stale data.
{ pkgs, config, ... }:
let
  # Matches the `ports = [ "3001:3000" ]` mapping in configuration.nix.
  imageApiUrl = "http://127.0.0.1:3001/api/v1/last-updated";
in
{
  systemd = {
    services.imageapi-freshness-metric = {
      description = "Emit imageapi last-updated freshness metric";
      after = [ "docker.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "imageapi-freshness-metric.sh" ''
          set -uo pipefail

          CURL=${pkgs.curl}/bin/curl
          JQ=${pkgs.jq}/bin/jq

          HOST="${config.networking.hostName}"
          TEXTFILE_DIR=/var/lib/node_exporter/textfiles
          OUT="$TEXTFILE_DIR/imageapi_freshness.prom"

          mkdir -p "$TEXTFILE_DIR"

          LAST_UPDATED=0
          SCRAPE_OK=0

          BODY=$($CURL -sf --max-time 15 "${imageApiUrl}" 2>/dev/null || echo "")

          if [[ -n "$BODY" ]]; then
            RAW=$($JQ -r '.lastUpdated // ""' <<<"$BODY" 2>/dev/null || echo "")
            if [[ -n "$RAW" && "$RAW" != "never" ]]; then
              # The API returns an ISO-8601 instant, e.g.
              # 2026-08-04T21:18:26.974Z. `date -d` parses that directly.
              PARSED=$(date -d "$RAW" +%s 2>/dev/null || echo "")
              if [[ "$PARSED" =~ ^[0-9]+$ ]]; then
                LAST_UPDATED=$PARSED
                SCRAPE_OK=1
              fi
            elif [[ "$RAW" == "never" ]]; then
              # The endpoint answered and the table is genuinely empty. That is a
              # successful scrape reporting a real fault, not a scrape failure --
              # keeping LAST_UPDATED at 0 lets the age alert fire, which is the
              # correct outcome for an updater that has never run.
              SCRAPE_OK=1
            fi
          fi

          TMP="$OUT.tmp"
          {
            echo "# HELP imageapi_last_updated_seconds Unix time of the newest imageapi lastUpdated row."
            echo "# TYPE imageapi_last_updated_seconds gauge"
            echo "imageapi_last_updated_seconds{host=\"$HOST\"} $LAST_UPDATED"

            # Emitted unconditionally so the age alert can require a successful
            # scrape. When nothing answers, the age metric above is written as 0,
            # so `time() - 0` reads as an enormous age -- without this flag the
            # alert would describe a stalled update loop when the real fault is
            # that the endpoint was unreachable.
            echo "# HELP imageapi_last_updated_scrape_success Whether the last-updated endpoint answered and parsed."
            echo "# TYPE imageapi_last_updated_scrape_success gauge"
            echo "imageapi_last_updated_scrape_success{host=\"$HOST\"} $SCRAPE_OK"
          } > "$TMP"
          mv "$TMP" "$OUT"
        '';
      };
    };

    timers.imageapi-freshness-metric = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # The update loop reschedules itself an hour after each run completes, so
        # the value moves at most hourly. Polling every 10 minutes is far more
        # often than needed but keeps the series responsive after a restart and
        # costs one loopback request.
        OnCalendar = "*:0/10";
        Persistent = true;
        RandomizedDelaySec = "60";
      };
    };
  };
}
