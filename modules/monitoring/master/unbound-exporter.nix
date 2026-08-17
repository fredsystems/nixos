# modules/monitoring/master/unbound-exporter.nix
#
# Prometheus metrics for the recursive resolver on this host.
#
# WHY
#
# sdrhub is the LAN's only DNS server, and until now nothing collected a single
# metric about it. Two total external-DNS outages -- 8 minutes on 2026-08-15,
# 29 minutes on 2026-08-16 -- produced no data at all. The first went entirely
# unnoticed. The second was diagnosed by reading journals for an hour, and the
# only reason it was noticed at all was the healthchecks.io deadman going quiet.
#
# The DNS probes added to blackbox.nix cover detection: they say resolution is
# broken, within two minutes, and which layer broke. What they cannot do is show
# a trend. A rising SERVFAIL rate, or one of the four DoT upstreams going lame
# while the others carry the load, is invisible to a probe that only asks
# whether one name resolved. That is what this exporter is for -- the
# degradation before the outage.
#
# WHAT IT NEEDS FROM UNBOUND
#
# `extended-statistics` and `statistics-cumulative`, both set in
# hosts/linux/sdrhub/configuration.nix. Neither is on by default and the
# exporter is close to worthless without them: no rcode counters at all without
# the first, and counters that reset on every read -- including a human's
# `unbound-control stats` -- without the second. The assertion below turns
# either of them being switched off into a build failure rather than a scrape
# that quietly reports nothing useful.
#
# EXPOSURE
#
# Loopback only, and no `openFirewall`, for the same reason as the blackbox
# exporter: the only consumer is the Prometheus instance on this same machine,
# and the metrics describe the resolver every device on the network depends on.
# Port 9167 is the upstream default and is unused elsewhere in this repo
# (verified against the config and against `ss -tlnp` on the host).
#
# CREDENTIALS
#
# None to manage. The NixOS exporter module runs the process as the `unbound`
# user whenever `services.unbound.enable` is true, which is exactly what is
# needed to read the control certificates in /var/lib/unbound (mode 0640,
# owned by unbound:unbound). It therefore talks to unbound's existing TCP
# control interface on 127.0.0.1:8953 with the default certificate paths, and
# needs no unix socket, no sops secret, and no group juggling.
{ config, lib, ... }:
let
  exporterHost = "127.0.0.1";
  exporterPort = 9167;
in
{
  assertions = [
    {
      assertion = config.services.unbound.settings.server.extended-statistics or false;
      message = ''
        modules/monitoring/master/unbound-exporter.nix needs
        services.unbound.settings.server.extended-statistics = true.

        Without it unbound emits no num.answer.rcode.* counters at all, so the
        exporter scrapes successfully while reporting none of the metrics it was
        added to collect -- including the SERVFAIL rate, which is the one that
        matters during a resolver outage.
      '';
    }
    {
      assertion = config.services.unbound.settings.server.statistics-cumulative or false;
      message = ''
        modules/monitoring/master/unbound-exporter.nix needs
        services.unbound.settings.server.statistics-cumulative = true.

        Without it unbound clears its counters every time they are read, so the
        exporter and anyone running `unbound-control stats` by hand each destroy
        the other's numbers, and Prometheus sees counter resets that did not
        correspond to a restart.
      '';
    }
  ];

  services.prometheus = {
    exporters.unbound = {
      enable = true;
      listenAddress = exporterHost;
      port = exporterPort;
      # openFirewall deliberately left at its default of false. See EXPOSURE.

      # Pin the identity to the static `unbound` user and group rather than
      # leaving it at the framework default of `unbound-exporter`.
      #
      # This is not cosmetic. The nixpkgs unbound exporter sets
      # `User = "unbound"` so it can read /var/lib/unbound/unbound_control.key
      # (mode 0640, owned by unbound:unbound), but it only sets
      # `DynamicUser = true` when services.unbound is DISABLED -- and the
      # generic exporter framework then defaults DynamicUser to true anyway
      # (`enableDynamicUser = serviceOpts.serviceConfig.DynamicUser or true`).
      # The rendered unit therefore carries DynamicUser=true together with a
      # statically allocated User=unbound, which reads like a contradiction.
      #
      # It happens to work: systemd honours the existing static user rather than
      # allocating a transient one, confirmed by running
      # `systemd-run -p DynamicUser=yes -p User=<static user> id`, which reports
      # the static uid. Access to the key then succeeds on the owner bits.
      #
      # Depending on that would mean depending on undocumented-looking systemd
      # behaviour for the exporter's ability to read its credentials, and on the
      # framework never gaining a static `unbound-exporter` user that would
      # shadow it. Naming both explicitly makes the identity unambiguous, keeps
      # the primary group aligned with the file ownership, and means this does
      # not quietly break if either upstream detail changes.
      user = "unbound";
      group = "unbound";
    };

    # Plain assignment, never lib.mkDefault -- scrapeConfigs is a list option,
    # and a mkDefault list is discarded wholesale by a normal-priority
    # definition rather than merged with it. Wrapping this would delete every
    # job declared in prometheus.nix and blackbox.nix the moment this module
    # loaded. Same reasoning as the note in blackbox.nix.
    scrapeConfigs = [
      {
        job_name = "unbound";
        static_configs = [
          {
            targets = [ "${exporterHost}:${toString exporterPort}" ];
            labels = {
              hostname = "sdrhub";
              role = "master";
              exporter = "unbound";
            };
          }
        ];
      }
    ];
  };

  # The exporter is useless if unbound is not actually running here. This module
  # is only imported by the monitoring-master role, which today is sdrhub alone
  # and does run unbound -- but the coupling is implicit, so state it.
  warnings = lib.optional (!config.services.unbound.enable) ''
    modules/monitoring/master/unbound-exporter.nix is imported on a host where
    services.unbound is disabled. The exporter will start and fail to reach a
    control interface on every scrape.
  '';
}
