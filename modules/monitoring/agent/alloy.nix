# modules/monitoring/agent/alloy.nix
#
# Grafana Alloy log shipper.  Replaces promtail, which was removed from
# nixpkgs in 25.11 → 26.05 (upstream EOL).
#
#   * Tails the systemd journal at /var/log/journal.
#   * Forwards to the Loki master at 192.168.31.20:5678 (tenant: default).
#   * Relabels journal `_SYSTEMD_UNIT` → `unit`,
#     `_CONTAINER_NAME` → `container`, `_CONTAINER_ID` → `container_id`.
#
# Alloy is deliberately a dumb shipper: it extracts no metrics and exposes
# nothing for Prometheus to scrape.  Log-derived alerting is evaluated
# centrally by the Loki ruler on sdrhub
# (modules/monitoring/master/loki-ruler.nix), so that tuning a pattern is a
# one-host deploy rather than a fleet-wide one.
#
# This module previously carried a `loki.process "docker"` block that
# incremented `sdr_service_failure_total` and `feeder_upstream_failure_total`
# counters.  Those counters were unreachable in three independent ways:
# Alloy's HTTP listener binds 127.0.0.1:12345 only, no Prometheus scrape job
# for Alloy ever existed, and the alert rules referred to them by their old
# `promtail_custom_` prefix.  The block and its firewall opening are removed
# rather than repaired.  Note that log shipping itself was never affected --
# `loki.write` is an outbound push and needs no inbound listener, which is
# why the roaming laptop works the same way.
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
      forward_to    = [loki.write.default.receiver]
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
  # journal access are all handled by the upstream module.  No firewall port
  # is opened: nothing needs to reach Alloy inbound.

  services.alloy = {
    enable = true;
    configPath = alloyConfig;
  };
}
