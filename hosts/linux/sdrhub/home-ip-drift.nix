{
  lib,
  pkgs,
  config,
  ...
}:
let
  expected = config.shared.homePublicIPv4;
in
{
  # Drift detection for the home public IPv4 address.
  #
  # WHAT THIS PROTECTS
  #
  # fredvps's fail2ban ignoreIP list contains the home address, and its decoy
  # jails run maxretry = 1. A single SYN to any of the 27 watched ports from an
  # address not on that list is an immediate host-wide DROP ban that escalates
  # to a week on repeat. Comcast rotates residential addresses, so the day the
  # address changes, that list silently stops protecting us -- and the reverse
  # is worse: the address we vacate gets handed to a stranger who is then
  # whitelisted across every jail on the internet-facing host.
  #
  # Neither failure is visible from fredvps. This makes it visible.
  #
  # WHY THE ORACLE IS OUR OWN NGINX LOG
  #
  # The question that matters is not "what is our public IP" in the abstract,
  # it is "what source address does fredvps attribute our traffic to", because
  # that is precisely the string ignoreIP has to match. Those can differ, and
  # only the second one is actionable.
  #
  # We already have the answer, continuously, for free: this host's blackbox
  # exporter probes ~30 public URLs on fredvps (see blackbox.nix -- they are
  # https:// targets, so they resolve to the public address and egress through
  # the home NAT rather than the tailnet), and fredvps's nginx logs the source
  # address of every one. Alloy ships that log here. Measured: 273 requests
  # carrying User-Agent "Blackbox-Exporter/0.28.0" in a 30-minute window.
  #
  # So the check is a local Loki query and nothing else. Rejected alternatives:
  #
  #   * A third-party echo service (ifconfig.me, api.ipify.org, OpenDNS
  #     myip.opendns.com). Puts an external dependency inside a security
  #     control, and answers the abstract question rather than the useful one.
  #   * A /whoami endpoint on fredvps returning $remote_addr. Self-hosted and
  #     direct, but adds public surface to the one internet-facing host in the
  #     fleet, which is the opposite of the direction that host has been moving.
  #   * ssh -p 2269 fredvps 'echo $SSH_CLIENT'. No new HTTP surface, but adds a
  #     scheduled login, sshd auth noise, and key management for a datum we are
  #     already logging.
  #
  # The cost of this choice is a four-link dependency chain: blackbox probing,
  # nginx logging, Alloy shipping, Loki retaining. Any link breaking means the
  # address cannot be determined -- which is why that case is reported as
  # up == 0 and alerted on separately, rather than being allowed to look like
  # agreement.
  # Alerts registered here rather than in prometheus.nix's central ruleFiles
  # list, following blackbox.nix and smartctl.nix: the module that owns the
  # metric owns its alerts, so the two cannot be added or removed separately.
  # ruleFiles is a list option, so this merges with the central list.
  services.prometheus.ruleFiles = [
    ../../../modules/monitoring/master/alert-rules/home-ip-alerts.yaml
  ];

  systemd = {
    services.home-ip-drift-metric = {
      description = "Compare the observed home public IP against the expected one";
      after = [ "loki.service" ];
      wants = [ "loki.service" ];

      serviceConfig = {
        Type = "oneshot";
        # Same lack of sandboxing as the other textfile generators on this
        # fleet: it needs to write into the root-owned directory node_exporter
        # reads. See modules/monitoring/agent/node_exporter.nix.
        ExecStart = pkgs.writeShellScript "home-ip-drift-metric.sh" ''
          set -uo pipefail

          export PATH=${
            lib.makeBinPath [
              pkgs.curl
              pkgs.jq
              pkgs.gnugrep
              pkgs.gawk
              pkgs.coreutils
            ]
          }

          TEXTFILE_DIR=/var/lib/node_exporter/textfiles
          OUT="$TEXTFILE_DIR/home_public_ip.prom"
          TMP="$OUT.$$"

          mkdir -p "$TEXTFILE_DIR"

          EXPECTED="${expected}"
          observed=""
          up=0

          # Newest matching line wins: limit=1 with direction=backward. The
          # 30-minute window is far wider than the blackbox probe interval, so a
          # single missed scrape cannot empty the result, but it is still short
          # enough that a rotation is reflected within minutes.
          #
          # `since` is a documented query_range parameter (it derives start from
          # end, and an explicit start would supersede it), not a Grafana-ism.
          # Called out because it reads like one: if Loki ignored it the window
          # would collapse and this check would report up=0 forever while Loki
          # was perfectly healthy. Verified against the live instance, which
          # returned the expected address for this exact request.
          if body=$(curl -sf --max-time 15 -G \
              http://127.0.0.1:5678/loki/api/v1/query_range \
              --data-urlencode 'query={host="fredvps", unit="nginx-access"} |= `Blackbox-Exporter/`' \
              --data-urlencode 'limit=1' \
              --data-urlencode 'since=30m' \
              --data-urlencode 'direction=backward'); then

            # nginx's combined format puts the client address first, so the
            # first whitespace-delimited field is the answer.
            candidate=$(printf '%s' "$body" \
              | jq -r '.data.result[0].values[0][1] // empty' \
              | awk '{ print $1 }')

            # Validated rather than trusted. An empty result, a Loki error
            # object, or a log-format change would otherwise be published as an
            # "observed address" that cannot possibly match, turning a broken
            # check into a false drift alert -- the failure mode most likely to
            # get this alert muted.
            if printf '%s' "$candidate" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
              observed="$candidate"
              up=1
            fi
          fi

          {
            echo "# HELP home_public_ip_check_up Whether the observed home public IP could be determined."
            echo "# TYPE home_public_ip_check_up gauge"
            echo "home_public_ip_check_up $up"

            # Both addresses ride along as LABELS rather than as separate _info
            # series, so the alert body is derivable from the alert itself.
            # The alternative -- annotations using `{{ with query ... }}` to look
            # up sibling series -- renders at notification time and therefore
            # needs Prometheus to be reachable exactly when something is already
            # wrong, and it is untestable without reproducing the sibling series
            # in every promtool case.
            #
            # The label set changing on rotation is deliberate and correct: the
            # old series ends, a new one begins, and the alert's `for:` clause
            # starts accumulating against the new state rather than inheriting
            # the old one's pending time. Cardinality is one series.
            echo "# HELP home_public_ip_matches_expected Whether the address fredvps observes matches the configured one."
            echo "# TYPE home_public_ip_matches_expected gauge"

            # Emitted only when the lookup succeeded. Publishing 0 on a failed
            # lookup would fire the drift alert for a monitoring fault, which is
            # exactly the conflation home_public_ip_check_up exists to prevent.
            if [ "$up" = "1" ]; then
              if [ "$observed" = "$EXPECTED" ]; then
                matches=1
              else
                matches=0
              fi
              printf 'home_public_ip_matches_expected{observed="%s",expected="%s"} %s\n' \
                "$observed" "$EXPECTED" "$matches"
            fi

            echo "# HELP home_public_ip_check_timestamp_seconds Unix time this file was last written."
            echo "# TYPE home_public_ip_check_timestamp_seconds gauge"
            printf 'home_public_ip_check_timestamp_seconds %s\n' "$(date +%s)"
          } > "$TMP"

          # Atomic replace: node_exporter reads this directory on every scrape
          # and must never see a partially written file.
          mv "$TMP" "$OUT"
        '';
      };
    };

    timers.home-ip-drift-metric = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # Every 10 minutes, matching the other textfile generators. A residential
        # address rotates on the order of months, so this is already far more
        # often than the event it watches for; the alert's `for:` clause is what
        # actually sets how fast we hear about it.
        OnBootSec = "5min";
        OnUnitActiveSec = "10min";
        AccuracySec = "30s";
        Persistent = true;
      };
    };
  };
}
