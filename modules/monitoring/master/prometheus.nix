{
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

in
{
  environment.systemPackages = [
    pkgs.prometheus.cli
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

          ExecStart = "${pkgs.writeShellScript "create-prometheus-snapshot" ''
            set -eu

            ${pkgs.curl}/bin/curl -XPOST http://localhost:9090/api/v1/admin/tsdb/snapshot
          ''}";
        };
      };
    };

    timers = {
      prunePrometheusSnapshots = {
        description = "Daily prune of Prometheus snapshots older than 30 days";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "daily"; # runs at 00:00 by default
          Persistent = true; # catch-up if system was down
        };
      };

      createPrometheusSnapshot = {
        description = "Scheduled Prometheus TSDB snapshot generation";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "daily";
          Persistent = true; # catch up after reboot
        };
      };
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
      ];

      scrapeConfigs = [
        # Only :9274 serves metrics.  Docker publishes 9273 and 9275 but no
        # process inside the ultrafeeder / dump978 containers listens on them,
        # so docker-proxy accepts the connection and immediately resets it.
        # Both were permanently down targets.  dump978 exposes its metrics
        # through the container's own nginx, which currently 404s on /metrics
        # (it reads /run/readsb/stats.prom, which does not exist), so there is
        # nothing to scrape for it at all until that is fixed container-side.
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
          job_name = "pushgateway";
          # honor_labels lets pushed metrics keep their own hostname/role if
          # they carry them; the static labels below are only a fallback.
          honor_labels = true;
          static_configs = [
            {
              targets = [ "127.0.0.1:9091" ];
              labels = {
                hostname = "sdrhub";
                role = "master";
              };
            }
          ];
        }
      ];

      alertmanager-ntfy = {
        enable = true;
        settings = {
          http = {
            addr = "127.0.0.1:8000";
          };
          ntfy = {
            baseurl = "https://ntfy.sh";
            notification = {
              # Both topic and priority accept gval expressions; the evaluation
              # context exposes the alert's `status`, `labels` and `annotations`.
              #
              # Critical alerts keep the pre-existing topic so an already
              # subscribed device continues to receive them without any action.
              # Everything else moves to a separate digest topic, which can be
              # muted independently while decoder thresholds are being tuned.
              #
              # NOTE: on public ntfy.sh a topic name is effectively a password.
              # Both names are in git history and should move to sops-backed
              # extraConfigFiles -- tracked in agent-docs/MONITORING.md.
              topic = ''
                labels["severity"] == "critical" ? "fred-sdrhub-alerts" : "fred-sdrhub-digest"
              '';
              priority = ''
                status == "resolved" ? "default" :
                labels["severity"] == "critical" ? "urgent" :
                labels["severity"] == "warning" ? "default" : "low"
              '';
              tags = [
                {
                  tag = "+1";
                  condition = ''status == "resolved"'';
                }
                {
                  tag = "rotating_light";
                  condition = ''status == "firing"'';
                }
              ];
              templates = {
                title = ''{{ if eq .Status "resolved" }}Resolved: {{ end }}{{ index .Annotations "summary" }}'';
                description = ''{{ index .Annotations "description" }}'';
              };
            };
          };
        };
      };

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
            receiver = "ntfy";
            group_by = [
              "alertname"
              "hostname"
            ];
            group_wait = "30s";
            group_interval = "5m";
            repeat_interval = "4h";

            # Per-severity pacing. All three land on the same receiver; the
            # ntfy topic and priority are chosen from the severity label by
            # the alertmanager-ntfy expressions above. Splitting here controls
            # how insistently each tier repeats.
            routes = [
              # The deadman must never reach ntfy: it fires permanently by
              # design. It is dispatched to its own receiver, which is a
              # blackhole until an external heartbeat URL is configured.
              # Matched first so it cannot fall through to a severity route
              # or to the parent receiver.
              {
                matchers = [ ''alertname="Watchdog"'' ];
                receiver = "watchdog";
                group_wait = "0s";
                group_interval = "1m";
                repeat_interval = "1m";
              }
              {
                matchers = [ ''severity="critical"'' ];
                receiver = "ntfy";
                group_wait = "30s";
                group_interval = "5m";
                repeat_interval = "1h";
              }
              {
                matchers = [ ''severity="warning"'' ];
                receiver = "ntfy";
                group_wait = "2m";
                group_interval = "30m";
                repeat_interval = "12h";
              }
              {
                # Informational tier. Deliberately slow: this is where decoder
                # throughput alerts land while their thresholds are unproven.
                matchers = [ ''severity="info"'' ];
                receiver = "ntfy";
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
            {
              name = "ntfy";

              webhook_configs = [
                {
                  url = "http://127.0.0.1:8000/hook";
                  send_resolved = true;
                }
              ];
            }

            # Deadman sink. Intentionally has no notification config, so the
            # permanently-firing Watchdog alert is dispatched here and
            # discarded instead of reaching ntfy.
            #
            # TO ACTIVATE THE DEADMAN: add a webhook_configs entry pointing at
            # an external heartbeat monitor that lives outside this stack --
            # a healthchecks.io ping URL, or an Uptime Kuma push URL hosted on
            # fredvps, which is off-site and would survive a whole-house
            # outage. The monitor alarms when the heartbeat stops, which is
            # the only way to distinguish "nothing is wrong" from "the
            # alerting pipeline is dead". Until then this rule is inert.
            {
              name = "watchdog";
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
