# modules/monitoring/agent/alloy.nix
#
# Grafana Alloy log/metric shipper.  Replaces promtail, which was removed
# from nixpkgs in 25.11 → 26.05 (upstream EOL).
#
# Feature parity with the prior promtail config:
#   * Tails the systemd journal at /var/log/journal.
#   * Forwards to the Loki master at 192.168.31.20:5678 (tenant: default).
#   * Relabels journal `_SYSTEMD_UNIT` → `unit`,
#     `_CONTAINER_NAME` → `container`, `_CONTAINER_ID` → `container_id`.
#   * For unit=docker-*, regex-matches "device not found" → counter
#     `sdr_service_failure_total`, and "connect ... fail" → counter
#     `feeder_upstream_failure_total`.
#
# Alloy default HTTP listener is 12345 (was 9080 on promtail); preserved
# in the firewall opening below in case a master ever scrapes the agent's
# own metrics.  No prometheus scrape job exists for it today
# (modules/monitoring/master/prometheus.nix has no agent self-scrape).
{
  config,
  pkgs,
  ...
}:
let
  alloyConfig = pkgs.writeText "agent.alloy" ''
    // Journal source: tail systemd journal and emit Loki entries.
    loki.source.journal "journal" {
      path          = "/var/log/journal"
      forward_to    = [loki.process.docker.receiver]
      relabel_rules = loki.relabel.journal.rules
      labels        = {
        job      = "journal",
        hostname = "${config.networking.hostName}",
        host     = "${config.networking.hostName}",
      }
    }

    // Relabel journal metadata into stable Loki labels.
    loki.relabel "journal" {
      forward_to = []

      rule {
        source_labels = ["__journal__systemd_unit"]
        target_label  = "unit"
      }
      rule {
        source_labels = ["__journal__container_name"]
        target_label  = "container"
      }
      rule {
        source_labels = ["__journal__container_id"]
        target_label  = "container_id"
      }
    }

    // For docker container units, regex-match known failure patterns and
    // emit counter metrics.  Counters are exposed on the Alloy /metrics
    // endpoint (default :12345) for prometheus to scrape if/when added.
    loki.process "docker" {
      forward_to = [loki.write.default.receiver]

      stage.match {
        selector = "{unit=~\"docker-.*\"}"

        stage.regex {
          expression = "(?P<sdr_err>device not found)|(?P<upstream_err>connect.*fail)"
        }

        stage.metrics {
          metric.counter {
            name        = "sdr_service_failure_total"
            description = "SDR-related USB/init failures"
            source      = "sdr_err"
            action      = "inc"
          }
          metric.counter {
            name        = "feeder_upstream_failure_total"
            description = "Upstream connection failures"
            source      = "upstream_err"
            action      = "inc"
          }
        }
      }
    }

    // Push to the central Loki master.
    loki.write "default" {
      endpoint {
        url       = "http://192.168.31.20:5678/loki/api/v1/push"
        tenant_id = "default"
      }
    }
  '';
in
{
  # Alloy module uses DynamicUser=true + StateDirectory=alloy +
  # SupplementaryGroups=["systemd-journal"], so the user, state dir, and
  # journal access are all handled by the upstream module.  Nothing extra
  # to declare beyond the firewall port and the service itself.

  networking.firewall.allowedTCPPorts = [
    12345 # alloy HTTP / metrics
  ];

  services.alloy = {
    enable = true;
    configPath = alloyConfig;
  };
}
