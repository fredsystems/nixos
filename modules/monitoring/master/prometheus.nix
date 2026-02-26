{
  lib,
  pkgs,
  agentNodes,
  agentScrapeMap,
  user,
  ...
}:
let
  agentHosts = agentNodes;

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
        ./alert-rules/system-alerts.yaml
        ./alert-rules/sdr-alerts.yaml
      ];

      scrapeConfigs = [
        {
          job_name = "ultrafeeder";
          static_configs = [
            {
              targets = [
                "sdrhub.local:9273"
                "sdrhub.local:9274"
              ];
            }
          ];
        }

        {
          job_name = "dump978";
          static_configs = [
            {
              targets = [
                "sdrhub.local:9275"
              ];
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
            { targets = [ "127.0.0.1:9090" ]; }
          ];
        }
        {
          job_name = "pushgateway";
          honor_labels = true;
          static_configs = [
            { targets = [ "127.0.0.1:9091" ]; }
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
              topic = "fred-sdrhub-alerts";
              priority = ''
                status == "firing" ? "high" : "default"
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
          };

          inhibit_rules = [
            {
              # When a node is completely down, suppress all the downstream alerts
              # it would otherwise generate (unit failures, container restarts, etc.)
              source_matchers = [ "alertname = \"NodeDown\"" ];
              target_matchers = [
                "alertname =~ \"SystemdUnitFailed|SystemdUnitFlapping|GithubRunnerCrashLoop|ContainerRestarting|ContainerOOM|DockerUnitFlapping|SDRServiceFailure|FeederUpstreamFailure|UltrafeederNoAircraft|UltrafeederNotReceiving|AdGuardHomeDown|AtticServerDown\""
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
