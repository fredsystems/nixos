{
  config,
  lib,
  pkgs,
  agentNodes,
  agentScrapeMap,
  desktopNodes,
  desktopScrapeMap,
  user,
  ...
}:
let
  agentHosts = agentNodes;
  desktopHosts = builtins.filter (h: h != "Daytona") desktopNodes;

  # Shared Pushover message body.
  #
  # Iterates .Alerts rather than using .CommonAnnotations: group_by is
  # [alertname, hostname], so a group can contain several alerts that differ
  # only by unit or device -- DecoderHeartbeatMissing across four dumpvdl2
  # instances, or the SMART rules across devices. Those have no common
  # description, and .CommonAnnotations.description would render empty.
  #
  # Pushover truncates at 1024 characters. Grouping by alertname and hostname
  # keeps groups small enough that this is not a practical concern.
  pushoverMessage = ''
    {{ range .Alerts }}{{ .Annotations.description }}
    {{ end }}'';
in
{
  environment.systemPackages = [
    pkgs.prometheus.cli
  ];

  #######################################
  # Deadman heartbeat endpoint
  #######################################
  # The healthchecks.io ping URL. Left owned by root: the alertmanager unit
  # runs with DynamicUser=yes, so there is no stable uid to chown to, and
  # LoadCredential below is the systemd-native way to hand a root-owned file
  # to such a service.
  # Alertmanager requires BOTH pushover values: it calls api.pushover.net
  # directly rather than being a hosted "Pushover-powered service", so it
  # supplies the application identity (api_token) as well as the recipient
  # (user_key).
  sops.secrets = {
    "healthchecks.io/endpoint" = { };
    "pushover/api_token" = { };
    "pushover/user_key" = { };

    # htpasswd file gating the prometheus.int.fredsystems.org vhost declared in
    # hosts/linux/sdrhub/configuration.nix.
    #
    # Prometheus has no authentication of its own, and `--web.enable-admin-api`
    # below means anything that can reach it can also delete the TSDB via
    # /api/v1/admin/tsdb/delete_series. Port 9090 stays open on the LAN because
    # daytona remote-writes to it (see the vhost comment for why closing it is
    # not on the table), so this does not make Prometheus unreachable without a
    # password -- it stops the TLS name from being a second unauthenticated
    # entry point, and gives a credential to rotate.
    #
    # Owned by nginx because nginx is what reads it, unlike the two pushover
    # secrets above which are handed to a DynamicUser unit via LoadCredential.
    #
    # restartUnits is deliberately NOT set. nginx opens this file per request
    # rather than caching it at startup, so a rotated hash takes effect without
    # a reload -- the failure mode that makes restartUnits necessary for
    # Grafana's `$__file{...}` secrets does not apply here.
    "monitoring/prometheus_htpasswd" = {
      owner = config.services.nginx.user;
      mode = "0400";
    };
  };

  # The alertmanager unit runs with DynamicUser=yes, so there is no stable uid
  # for sops to chown these to. LoadCredential reads them as root at unit
  # start and exposes them to the service user under a deterministic path,
  # which is exactly what it exists for.
  systemd.services.alertmanager.serviceConfig.LoadCredential = [
    "hc-endpoint:${config.sops.secrets."healthchecks.io/endpoint".path}"
    "pushover-token:${config.sops.secrets."pushover/api_token".path}"
    "pushover-user-key:${config.sops.secrets."pushover/user_key".path}"
  ];

  system.activationScripts.prometheus_activation = {
    text = ''
      # Ensure directory exists (does not touch contents if already there)
      install -d -m0755 -o fred -g users /opt/monitoring/prometheus
      install -d -m0755 -o prometheus -g prometheus /var/lib/prometheus2/data/snapshots
    '';
    deps = [ ];
  };

  systemd = {
    services = {
      prometheus.serviceConfig = {
        WorkingDirectory = lib.mkForce "/opt/monitoring/prometheus";
      };

      setPrometheusACL = {
        description = "Apply ACLs to Prometheus snapshot directory";
        after = [ "prometheus.service" ];
        wantedBy = [ "multi-user.target" ];

        serviceConfig = {
          Type = "oneshot";

          ExecStart = ''
            ${pkgs.coreutils}/bin/install -d -m0755 -o prometheus -g prometheus /var/lib/prometheus2/data/snapshots
          '';

          ExecStartPost = ''
            ${pkgs.acl}/bin/setfacl -R -m u:${user}:rX /var/lib/prometheus2
            ${pkgs.acl}/bin/setfacl -R -m u:${user}:rX /var/lib/prometheus2/data
            ${pkgs.acl}/bin/setfacl -R -m u:${user}:rX /var/lib/prometheus2/data/snapshots
            ${pkgs.acl}/bin/setfacl -R -m d:u:${user}:rX /var/lib/prometheus2/data/snapshots
          '';
        };
      };

      # Prune Prometheus snapshots older than 30 days
      prunePrometheusSnapshots = {
        description = "Prune Prometheus snapshots older than 30 days";
        # Snapshots must exist before pruning
        after = [ "prometheus.service" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.writeShellScript "prune-prometheus-snapshots" ''
            set -eu

            SNAPSHOT_DIR="/var/lib/prometheus2/data/snapshots"

            if [ -d "$SNAPSHOT_DIR" ]; then
              # Delete directories older than 30 days
              ${pkgs.toybox}/bin/find "$SNAPSHOT_DIR"/* -maxdepth 0 -type d -mtime +30 -print -exec  ${pkgs.toybox}/bin/rm -rf {} +
            fi
          ''}";
        };
      };

      createPrometheusSnapshot = {
        description = "Create Prometheus TSDB snapshot";
        after = [ "prometheus.service" ];
        wants = [ "prometheus.service" ];

        serviceConfig = {
          Type = "oneshot";

          # -f, and the response check, are both load-bearing.
          #
          # Without -f, curl exits 0 on an HTTP error. This endpoint is only
          # available while --web.enable-admin-api is set, so if that flag were
          # ever dropped -- as AUDIT-2026-08-04.md item 1.5 proposed before the
          # premise was corrected -- Prometheus would answer 404/403, curl would
          # exit 0, `set -e` would not trigger, and this unit would report
          # success while producing no snapshot at all. The backup would then be
          # silently frozen at whatever the last real snapshot was, and the NAS
          # would keep dutifully mirroring it.
          #
          # That is the precise failure this whole change exists to remove, and
          # it was live in the one job the fleet already had.
          #
          # The grep is a second, independent assertion: a 200 whose body does
          # not contain a snapshot name means the API changed shape or returned
          # a JSON error with a success status, which -f alone would accept.
          #
          # WHY THE READINESS WAIT
          #
          # `after`/`wants` above order this unit against prometheus.service
          # STARTING, not against it listening on 9090. Prometheus replays its
          # WAL on startup and only binds once that finishes, which on this host
          # takes appreciably longer than the 90-day TSDB makes obvious.
          #
          # That gap is reachable in practice, not in theory. This timer is
          # Persistent=true, so any activation that has passed the day's
          # OnCalendar triggers an immediate catch-up run -- and any change to
          # Prometheus' own config (adding a rule file, for instance) restarts
          # prometheus.service in the same activation. The two then race, curl
          # gets ECONNREFUSED, and the unit fails: exactly what happened when
          # this backup work was first deployed.
          #
          # Waiting on /-/ready rather than sleeping is what makes this
          # deterministic. /-/ready is Prometheus' own readiness endpoint and
          # returns 503 until the WAL replay completes, so this polls the actual
          # precondition instead of guessing at a duration. 60 attempts at 2s
          # bounds it at two minutes, after which failing is correct: at that
          # point Prometheus really is broken and a silent skip would be the
          # false signal this job exists to avoid.
          ExecStart = "${pkgs.writeShellScript "create-prometheus-snapshot" ''
            set -euo pipefail

            CURL=${pkgs.curl}/bin/curl

            for _ in $(${pkgs.coreutils}/bin/seq 1 60); do
              if $CURL -sf --max-time 5 http://localhost:9090/-/ready >/dev/null; then
                break
              fi
              ${pkgs.coreutils}/bin/sleep 2
            done

            # Deliberately re-checked rather than tracking the loop's exit: if
            # readiness never arrived, say so in the journal instead of letting
            # the snapshot call fail with a bare connection error that looks
            # like a networking fault.
            if ! $CURL -sf --max-time 5 http://localhost:9090/-/ready >/dev/null; then
              echo "prometheus did not become ready within 120s; not snapshotting" >&2
              exit 1
            fi

            response=$($CURL -sf --max-time 300 \
              -XPOST http://localhost:9090/api/v1/admin/tsdb/snapshot)

            if ! printf '%s' "$response" | ${pkgs.gnugrep}/bin/grep -q '"name"'; then
              echo "snapshot API answered without a snapshot name: $response" >&2
              exit 1
            fi

            printf 'created snapshot: %s\n' "$response"
          ''}";
        };
      };
    };

    timers = {
      # These two both fired at exactly 00:00 with no jitter, so the prune and
      # the snapshot raced every night. The practical risk was low -- the prune
      # only deletes directories older than 30 days, so it was never going to
      # delete the snapshot being created -- but the ordering was undefined and
      # the fleet's convention is to jitter fixed-time daily jobs (see
      # discord-backup.nix and the audit's item 3.4).
      #
      # The offsets also give them a deliberate order: prune first to free
      # space, then snapshot into it. That matters on sdrhub, whose NVMe is at
      # 54% of rated write endurance (alert-rules/smart-alerts.yaml:9-17).
      prunePrometheusSnapshots = {
        description = "Daily prune of Prometheus snapshots older than 30 days";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "daily"; # runs at 00:00 by default
          Persistent = true; # catch-up if system was down
          RandomizedDelaySec = "5m";
        };
      };

      createPrometheusSnapshot = {
        description = "Scheduled Prometheus TSDB snapshot generation";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          # 00:10 rather than 00:00, so the snapshot starts after the prune's
          # jitter window (00:00-00:05) has closed and the two no longer
          # overlap. Ordering is then prune-then-snapshot: free the space
          # before writing into it.
          #
          # Still ~3h45m of slack before the NAS pulls at 04:00 wall-clock
          # (0300 on the NAS, which is not DST-corrected -- see
          # BACKUP-DESIGN.md Part 0).
          OnCalendar = "*-*-* 00:10:00";
          Persistent = true; # catch up after reboot
          RandomizedDelaySec = "5m";
        };
      };
    };
  };

  # Verification for the snapshot job above.
  #
  # Declared alongside the job it watches, so the two cannot drift apart. See
  # modules/monitoring/agent/backup-freshness.nix for what this does and does
  # not prove -- in particular, it says nothing about whether the NAS pulled
  # these snapshots, only that they exist and are fresh on this host.
  #
  # This is also the closest thing the fleet had to a working backup, and it
  # was entirely unwatched: AUDIT-2026-08-04.md notes the snapshots live on the
  # same disk as the TSDB they snapshot, which makes them corruption insurance
  # rather than loss insurance. Knowing they are being produced is the
  # precondition for making them anything better.
  services.backupFreshness = {
    enable = true;
    artifacts.prometheus-tsdb = {
      path = "/var/lib/prometheus2/data/snapshots";

      # Snapshots are directories, not files. Prometheus names them
      # <unix>-<hex>, so there is no stable prefix to match on and `*` is
      # correct here -- `kind = "directory"` plus -maxdepth 1 is what keeps
      # this from descending into the block directories inside each snapshot.
      kind = "directory";

      # 30 hours, same reasoning as the Discord dump: the job is daily with up
      # to 5 minutes of jitter, so a healthy age peaks just over 24h.
      maxAgeSeconds = 108000;

      # 30-day retention (prunePrometheusSnapshots), so ~30 is healthy. 40
      # catches the prune having stopped. This bound matters more than it looks:
      # each snapshot is a hardlink farm against the live TSDB, so a prune that
      # stops working pins every block it references and the data directory
      # grows without any single snapshot looking large.
      maxCount = 40;

      description = "Prometheus TSDB snapshots";
    };
  };

  networking.firewall.allowedTCPPorts = [
    9090 # Prometheus
    9093 # Alertmanager
  ];

  #######################################
  # Prometheus
  #######################################
  services = {
    prometheus = {
      enable = true;

      # Explicit listen address
      listenAddress = "0.0.0.0";
      port = 9090;

      # Prometheus now requires extraFlags for TSDB paths
      extraFlags = [
        "--storage.tsdb.retention.time=90d"
        "--web.enable-admin-api"
        "--web.enable-remote-write-receiver"
      ];

      globalConfig = {
        scrape_interval = "15s";
        evaluation_interval = "15s";
      };

      alertmanagers = [
        {
          scheme = "http";
          static_configs = [
            { targets = [ "127.0.0.1:9093" ]; }
          ];
        }
      ];

      ruleFiles = [
        ./alert-rules/alert-rules.yaml
        ./alert-rules/docker-rules.yaml
        ./alert-rules/firmware-alerts.yaml
        ./alert-rules/system-alerts.yaml
        ./alert-rules/sdr-alerts.yaml
        ./alert-rules/meta-alerts.yaml
        ./alert-rules/capacity-alerts.yaml
        ./alert-rules/fail2ban-alerts.yaml
        ./alert-rules/github-alerts.yaml
        ./alert-rules/frigate-alerts.yaml
      ];

      scrapeConfigs = [
        # Ultrafeeder serves metrics on :9274 only. Docker also publishes 9273,
        # but nothing inside the container listens on it, so docker-proxy
        # accepts the connection and immediately resets it -- it was a
        # permanently down target and is not scraped.
        {
          job_name = "ultrafeeder";
          static_configs = [
            {
              targets = [
                "sdrhub.local:9274"
              ];
              labels = {
                hostname = "sdrhub";
                role = "master";
              };
            }
          ];
        }

        # dump978 UAT decoder. Serves telegraf's prometheus_client output on
        # 9275, which only works on the `telegraf-*` image variant -- the
        # `latest-*` variant omits the telegraf binary and its s6 services
        # silently sleep, which is why this target was previously down.
        {
          job_name = "dump978";
          static_configs = [
            {
              targets = [
                "sdrhub.local:9275"
              ];
              labels = {
                hostname = "sdrhub";
                role = "master";
              };
            }
          ];

          metric_relabel_configs = [
            # Belt and braces against the per-aircraft cardinality bomb.
            # INFLUXDB_SKIP_AIRCRAFT=true on the container stops telegraf
            # collecting these at all, which is the real fix; this drop means
            # that if the env var is ever lost or a future image ignores it,
            # Prometheus still refuses to ingest 23 unbounded families keyed on
            # aircraft address, callsign and flightplan id.
            {
              source_labels = [ "__name__" ];
              regex = "aircraft_.*";
              action = "drop";
            }

            # telegraf tags everything with host=<container id>, which changes
            # every time the container is recreated. Left in place it would
            # churn the series set on each restart and break continuity of the
            # very counters this job exists to watch. hostname comes from the
            # static labels above instead.
            {
              regex = "host";
              action = "labeldrop";
            }
          ];
        }

        {
          job_name = "acarshub";
          static_configs = [
            {
              targets = [
                "sdrhub.local:8085"
              ];
              labels = {
                hostname = "sdrhub";
                role = "master";
              };
            }
          ];
        }

        # Frigate NVR on nvrhub.
        #
        # Port 9634 is frigate-metrics-relay, not Frigate and not nginx's public
        # vhost. Frigate's /api/metrics requires authentication inside Frigate
        # itself and only waives it for requests arriving on nginx's
        # 127.0.0.1:5000 listener, so scraping :80 directly returns 401. The
        # relay is a plain TCP forwarder to that loopback listener, which
        # preserves the port the auth decision is made on. The full reasoning,
        # including two approaches that did not work, is in
        # hosts/linux/nvrhub/frigate.nix.
        #
        # 30s rather than the 15s default: Frigate recomputes these values from
        # its own stats loop roughly every 5s, and the alert rules all evaluate
        # over minutes, so a faster scrape would add series churn for no signal.
        {
          job_name = "frigate";
          scrape_interval = "30s";
          metrics_path = "/api/metrics";
          static_configs = [
            {
              targets = [ "nvrhub.local:9634" ];
              labels = {
                hostname = "nvrhub";
                role = "agent";
                exporter = "frigate";
              };
            }
          ];
        }

        {
          job_name = "node";
          static_configs =
            (map (h: {
              targets = [ "${agentScrapeMap.${h}}:9100" ];
              labels = {
                hostname = h;
                role = "agent";
                exporter = "node";
              };
            }) agentHosts)
            ++ (map (h: {
              targets = [ "${desktopScrapeMap.${h}}:9100" ];
              labels = {
                hostname = h;
                role = "desktop";
                exporter = "node";
              };
            }) desktopHosts)
            ++ [
              {
                targets = [ "sdrhub.local:9100" ];
                labels = {
                  hostname = "sdrhub";
                  role = "master";
                  exporter = "node";
                };
              }
            ];
        }

        {
          job_name = "cadvisor";
          static_configs =
            (map (h: {
              targets = [ "${agentScrapeMap.${h}}:4567" ];
              labels = {
                hostname = h;
                role = "agent";
                exporter = "cadvisor";
              };
            }) agentHosts)
            ++ [
              {
                targets = [ "sdrhub.local:4567" ];
                labels = {
                  hostname = "sdrhub";
                  role = "master";
                  exporter = "cadvisor";
                };
              }
            ];
        }

        {
          # fail2ban ban/jail state. fredvps only -- it is the sole host with
          # a public interface and therefore the only one running fail2ban.
          # Scraped over Tailscale, like every other exporter on that host.
          job_name = "fail2ban";
          static_configs = [
            {
              targets = [ "${agentScrapeMap.fredvps}:9191" ];
              labels = {
                hostname = "fredvps";
                role = "agent";
                exporter = "fail2ban";
              };
            }
          ];
        }

        {
          job_name = "prometheus";
          static_configs = [
            {
              targets = [ "127.0.0.1:9090" ];
              labels = {
                hostname = "sdrhub";
                role = "master";
              };
            }
          ];
        }

        # The monitoring stack monitored everything except itself. Without
        # these, a failure of Alertmanager or Loki produces silence, which is
        # indistinguishable from health.
        {
          job_name = "alertmanager";
          static_configs = [
            {
              targets = [ "127.0.0.1:9093" ];
              labels = {
                hostname = "sdrhub";
                role = "master";
              };
            }
          ];
        }

        {
          job_name = "loki";
          static_configs = [
            {
              targets = [ "127.0.0.1:5678" ];
              labels = {
                hostname = "sdrhub";
                role = "master";
              };
            }
          ];
        }

        {
          job_name = "grafana";
          static_configs = [
            {
              targets = [ "127.0.0.1:3333" ];
              labels = {
                hostname = "sdrhub";
                role = "master";
              };
            }
          ];
        }

        {
          # GitHub CI visibility. Loopback-only: the exporter holds a token.
          #
          # A collection cycle sweeps ~60 repositories and can take a couple of
          # minutes, but it runs on its own timer and only publishes results
          # when complete, so the scrape itself is cheap. The default 10s
          # timeout is fine.
          job_name = "github-ci";
          static_configs = [
            {
              targets = [ "127.0.0.1:9418" ];
              labels = {
                hostname = "sdrhub";
                role = "master";
              };
            }
          ];
        }
        {
          job_name = "pushgateway";

          # honor_labels keeps whatever labels the pusher supplied. Deliberately
          # NO static hostname/role here: with honor_labels those are only a
          # fallback, so a series pushed from another machine that omitted
          # hostname would silently inherit hostname="sdrhub", role="master" and
          # be attributed to the wrong host. A missing hostname is easier to
          # notice than a wrong one.
          #
          # Nothing pushes to the gateway today; whatever starts doing so should
          # set its own hostname.
          honor_labels = true;
          static_configs = [
            { targets = [ "127.0.0.1:9091" ]; }
          ];
        }
      ];

      #######################################
      # Alertmanager
      #######################################
      alertmanager = {
        enable = true;

        listenAddress = "0.0.0.0";
        port = 9093;

        configuration = {
          global = {
            resolve_timeout = "5m";
          };

          route = {
            # Fallback for any alert without a matching severity child route.
            receiver = "pushover-warning";
            group_by = [
              "alertname"
              "hostname"
            ];
            group_wait = "30s";
            group_interval = "5m";
            repeat_interval = "4h";

            # Per-severity pacing. All three land on the same receiver; the
            # Each severity has its own Pushover receiver, which is where the
            # priority, sound and retry behaviour is set. Splitting here controls
            # how insistently each tier repeats.
            routes = [
              # The deadman must never reach Pushover: it fires permanently by
              # design. It is dispatched to its own receiver, which is a
              # blackhole until an external heartbeat URL is configured.
              # Matched first so it cannot fall through to a severity route
              # or to the parent receiver.
              {
                matchers = [ ''alertname="Watchdog"'' ];
                receiver = "watchdog";
                group_wait = "0s";

                # Effective ping cadence is 2 minutes, and stating
                # repeat_interval = 2m makes the config match what actually
                # happens rather than looking like it produces 1m.
                #
                # Alertmanager only re-evaluates whether to notify on each
                # group_interval tick, and its dedup stage sends only when
                # `lastNotify < now - repeat_interval`. With repeat_interval
                # equal to group_interval, the tick at exactly one interval
                # fails that test by a hair and the notification slips to the
                # next tick. So any repeat_interval >= group_interval yields a
                # real cadence of 2 x group_interval. Measured against the
                # healthchecks.io ping log: 09:25, 09:27, 09:29.
                group_interval = "1m";
                repeat_interval = "2m";
              }
              # Fleet-wide deploy-state alerts, grouped by alertname ALONE so a
              # single cause produces a single notification.
              #
              # The parent route groups by (alertname, hostname), which is right
              # for per-host faults but wrong here: one legitimate change to a
              # shared input (a nixpkgs-stable bump, a modules/ edit) moves every
              # server's closure at once, and under the parent grouping that
              # arrives as seven separate Pushover pushes for one action. The
              # action is fleet-wide -- deploy the servers -- so the
              # notification should be too.
              #
              # Matched before the severity routes below, which would otherwise
              # claim these on severity="warning". Individual hosts remain
              # identifiable: each alert instance is still listed in the grouped
              # notification body, which pushoverMessage renders per-alert.
              {
                matchers = [
                  ''alertname=~"NixOSDeployDrift|NixOSUnmanagedSystem|NixOSDeployStateUnknown|NixOSManifestFetchStalled|NixOSFleetManifestStale"''
                ];
                receiver = "pushover-warning";
                group_by = [ "alertname" ];
                # Longer than the parent's 30s: a fleet-wide change trips hosts a
                # few scrape intervals apart, and a short group_wait would split
                # one cause across two notifications anyway.
                group_wait = "5m";
                group_interval = "30m";
                # Deploy drift is not urgent and self-resolves on the next
                # deploy. Daily is enough to stay on the radar without becoming
                # background noise -- the failure mode this rewrite targets.
                repeat_interval = "24h";
              }
              {
                matchers = [ ''severity="critical"'' ];
                receiver = "pushover-critical";
                group_wait = "30s";
                group_interval = "5m";
                repeat_interval = "1h";
              }
              {
                matchers = [ ''severity="warning"'' ];
                receiver = "pushover-warning";
                group_wait = "2m";
                group_interval = "30m";
                repeat_interval = "12h";
              }
              {
                # Informational tier. Deliberately slow: this is where decoder
                # throughput alerts land while their thresholds are unproven.
                matchers = [ ''severity="info"'' ];
                receiver = "pushover-info";
                group_wait = "5m";
                group_interval = "1h";
                repeat_interval = "24h";
              }
            ];
          };

          inhibit_rules = [
            {
              # When a node is down, everything else observed on that node is a
              # consequence, so suppress all of it and page once for the cause.
              #
              # Matching on "not NodeDown" rather than an explicit alertname
              # list is deliberate: the previous list had to be edited by hand
              # for every new alert, and had already gone stale, still naming
              # two rules that no longer exist. It also omitted
              # PrometheusTargetDown, which a downed node always triggers.
              #
              # Alerts with no hostname label (the Watchdog deadman, for
              # example) are never inhibited by this rule: `equal` requires the
              # label to match, and NodeDown always carries a non-empty
              # hostname from the node job.
              source_matchers = [ ''alertname="NodeDown"'' ];
              target_matchers = [ ''alertname!="NodeDown"'' ];
              equal = [ "hostname" ];
            }
            {
              # A dockerd failure otherwise produces one alert per container
              # on the host -- eighteen of them on sdrhub. Page for the cause
              # and suppress the consequences.
              source_matchers = [ ''alertname="DockerDaemonDown"'' ];
              target_matchers = [
                ''alertname=~"ContainerRestarting|ContainerOOM|ContainerUnhealthy|DockerUnitFlapping|SDRDecoderCrashed|DecoderHeartbeatMissing|UltrafeederNoAircraft|UltrafeederNotReceiving"''
              ];
              equal = [ "hostname" ];
            }
          ];

          receivers = [
            # Pushover, one receiver per severity rather than one receiver with
            # a templated priority. Pushover's emergency priority requires
            # retry/expire, and each tier wants a different sound and repeat
            # behaviour, so separate receivers are clearer than nested
            # conditionals in a template.
            #
            # Both credentials come from sops via LoadCredential: the
            # alertmanager unit runs DynamicUser=yes so there is no stable uid
            # to chown to, and *_file keeps the secrets out of the Nix store
            # while preserving build-time amtool validation.
            #
            # Alertmanager requires BOTH token and user_key. It talks to
            # api.pushover.net directly rather than being a hosted
            # "Pushover-powered service", so it supplies the application
            # identity as well as the recipient.
            {
              name = "pushover-critical";

              pushover_configs = [
                {
                  token_file = "/run/credentials/alertmanager.service/pushover-token";
                  user_key_file = "/run/credentials/alertmanager.service/pushover-user-key";
                  send_resolved = true;

                  # Priority 2 is emergency: Pushover re-alerts until the
                  # notification is acknowledged, and it bypasses quiet hours.
                  # This is the capability the previous ntfy setup did not
                  # have -- an unseen critical alert was simply lost.
                  priority = "2";
                  retry = "2m";
                  expire = "1h";
                  sound = "siren";

                  title = ''{{ if eq .Status "resolved" }}RESOLVED: {{ end }}{{ .CommonLabels.alertname }}{{ if .CommonLabels.hostname }} on {{ .CommonLabels.hostname }}{{ end }}'';
                  message = pushoverMessage;
                  url = "{{ (index .Alerts 0).GeneratorURL }}";
                  url_title = "Open in Prometheus";
                }
              ];
            }

            {
              name = "pushover-warning";

              pushover_configs = [
                {
                  token_file = "/run/credentials/alertmanager.service/pushover-token";
                  user_key_file = "/run/credentials/alertmanager.service/pushover-user-key";
                  send_resolved = true;

                  # Normal priority: notifies, respects quiet hours, no retry.
                  priority = "0";

                  title = ''{{ if eq .Status "resolved" }}RESOLVED: {{ end }}{{ .CommonLabels.alertname }}{{ if .CommonLabels.hostname }} on {{ .CommonLabels.hostname }}{{ end }}'';
                  message = pushoverMessage;
                  url = "{{ (index .Alerts 0).GeneratorURL }}";
                  url_title = "Open in Prometheus";
                }
              ];
            }

            {
              name = "pushover-info";

              pushover_configs = [
                {
                  token_file = "/run/credentials/alertmanager.service/pushover-token";
                  user_key_file = "/run/credentials/alertmanager.service/pushover-user-key";
                  # Informational alerts do not need a resolved notification;
                  # this is the tier decoder throughput lands in while its
                  # thresholds are unproven and it would double the volume.
                  send_resolved = false;

                  # Priority -1 is low: delivered silently, no sound or
                  # vibration. Visible when the phone is picked up.
                  priority = "-1";

                  title = "{{ .CommonLabels.alertname }}{{ if .CommonLabels.hostname }} on {{ .CommonLabels.hostname }}{{ end }}";
                  message = pushoverMessage;
                  url = "{{ (index .Alerts 0).GeneratorURL }}";
                  url_title = "Open in Prometheus";
                }
              ];
            }

            # Deadman sink.
            #
            # The Watchdog alert fires permanently by design, so its ARRIVAL at
            # healthchecks.io is the signal, not its content. healthchecks.io
            # expects a ping on a schedule and alarms when one stops arriving,
            # over infrastructure and a network path that share nothing with
            # this stack.
            #
            # This is the only check that covers the delivery path itself. A
            # successful ping proves Prometheus is evaluating rules, can reach
            # Alertmanager, that Alertmanager is dispatching and its routing
            # tree resolves, and that this host has working outbound DNS and
            # network. Every other alert in this repo assumes all of that.
            #
            # It cannot be done from inside: AlertmanagerDown and friends are
            # evaluated by Prometheus and delivered by Alertmanager, so they
            # catch partial failure but never total failure -- the component
            # that would report it is the one that is broken.
            #
            # url_file rather than url keeps the ping URL out of the Nix store.
            # It reads from the systemd credential directory rather than
            # /run/secrets directly because the alertmanager unit runs with
            # DynamicUser=yes, so there is no static uid for sops to chown to.
            # LoadCredential (below) copies it in as root at unit start and
            # exposes it to the service user at a deterministic path.
            {
              name = "watchdog";

              webhook_configs = [
                {
                  url_file = "/run/credentials/alertmanager.service/hc-endpoint";
                  # Watchdog never resolves, so there is nothing to send.
                  send_resolved = false;
                }
              ];
            }
          ];
        };
      };

      #######################################
      # Pushgateway
      #######################################
      pushgateway = {
        enable = true;

        # If you want bind to localhost-only:
        extraFlags = [
          "--web.listen-address=127.0.0.1:9091"
        ];
      };
    };
  };
}
