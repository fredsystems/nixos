# modules/monitoring/agent/alloy.nix
#
# Grafana Alloy log shipper.  Replaces promtail, which was removed from
# nixpkgs in 25.11 → 26.05 (upstream EOL).
#
#   * Tails the systemd journal at /var/log/journal.
#   * Forwards to the Loki master at 192.168.31.20:5678 (tenant: default).
#   * Relabels journal `_SYSTEMD_UNIT` → `unit`. Two further rules map
#     `_CONTAINER_NAME` / `_CONTAINER_ID`, but both are inert -- those fields
#     came from dockerd's journald log driver, which this fleet no longer uses.
#     Container logs arrive as `unit="docker-<name>.service"` instead. See the
#     note on those rules below before relying on a `container` label.
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
  lib,
  pkgs,
  ...
}:
let
  # nginx's access log is a FILE, not a journal stream. nginx writes it via
  # its compiled-in default path (there is no access_log directive in the
  # generated config), and only stderr goes to the journal -- so the journal
  # source below never sees a single request line.
  #
  # That matters because the 444s emitted by the probe-blocking rule are the
  # raw record of who is scanning us, and they are what the nginx-probe
  # fail2ban jail keys on. Without this source the security dashboard can
  # show that bans happened but not what provoked them.
  #
  # Redirecting nginx to log to stdout instead would put it in the journal
  # for free, but fail2ban's jails read the file, so that would mean moving
  # them onto a journal backend at the same time. Tailing the file is the
  # smaller change and leaves the jails untouched.
  nginxLogSource = lib.optionalString config.services.nginx.enable ''
    // nginx access log (file, not journal -- see the comment in alloy.nix).
    local.file_match "nginx" {
      path_targets = [{
        __path__ = "/var/log/nginx/access.log",
        job      = "nginx",
        hostname = "${config.networking.hostName}",
        host     = "${config.networking.hostName}",
        unit     = "nginx-access",
      }]
    }

    loki.source.file "nginx" {
      targets    = local.file_match.nginx.targets
      forward_to = [loki.write.default.receiver]
    }
  '';

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
      // These two are INERT, and were already inert before the log-driver
      // change described below. Recorded rather than deleted because the
      // reasoning is worth keeping.
      //
      // _CONTAINER_NAME and _CONTAINER_ID are attached by dockerd's journald
      // log driver, not by systemd, so they only ever appeared on the
      // duplicate copy of each container's output that dockerd wrote directly
      // (see the long comment in modules/services/adsb-docker-units.nix).
      // Verified against the live Loki instance on 2026-08-18: its /labels
      // endpoint lists only filename, host, hostname, job, service_name and
      // unit -- no `container` label has ever existed there, so nothing has
      // ever queried one.
      //
      // As of the switch to `log-driver = "local"`, dockerd no longer writes
      // to the journal at all, so these fields cannot appear even in
      // principle. Container output still reaches Loki via each container's
      // wrapper unit as unit="docker-<name>.service", which is what the nine
      // Loki alert rules and the Container Logs dashboard panel select on.
      //
      // Left in place deliberately: a relabel rule whose source label is
      // absent is a no-op, so these cost nothing, and keeping them means the
      // config still does the right thing if a host is ever moved back to the
      // journald driver. Do not "fix" them by adding a container label to
      // queries -- there is nothing to query.
      rule {
        source_labels = ["__journal__container_name"]
        target_label  = "container"
      }
      rule {
        source_labels = ["__journal__container_id"]
        target_label  = "container_id"
      }
    }

    ${nginxLogSource}

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

  # /var/log/nginx/access.log is nginx:nginx 0640, and Alloy runs as a
  # DynamicUser whose only supplementary group is systemd-journal. Without
  # this it cannot open the file, and loki.source.file fails silently -- the
  # dashboard would show an empty panel with no error anywhere obvious.
  systemd.services.alloy.serviceConfig.SupplementaryGroups = lib.mkIf config.services.nginx.enable [
    config.services.nginx.group
  ];
}
