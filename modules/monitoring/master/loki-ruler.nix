# modules/monitoring/master/loki-ruler.nix
#
# Log-derived alerting and recording rules, evaluated by Loki's ruler on the
# monitoring master.
#
# Rules live here rather than in Alloy's `loki.process` stages because these
# patterns need frequent tuning against real decoder behaviour, and a change
# here is a single-host deploy instead of a six-host colmena run. It also means
# Alloy never has to be scrapeable by Prometheus.
#
# Alerting rules are delivered to Alertmanager directly. Recording rules are
# remote-written into Prometheus so the derived series are usable in Grafana
# and in ordinary PromQL alongside cAdvisor and node_exporter data.
#
# IMPORTANT -- two LogQL behaviours shape every rule below:
#
#   * `count_over_time` with a line filter returns NO SERIES when nothing
#     matches, rather than zero. Any rule of the form `count_over_time(...) == 0`
#     is therefore dead on arrival. Absence must be expressed with
#     `absent_over_time`, which does return 1 and preserves the selector labels.
#   * Consequently every "something bad happened" rule here is `> N`, which only
#     needs matching lines to exist, and every "something stopped" rule uses
#     `absent_over_time` against an explicit selector.
#
# EVERY HOST-SCOPED RULE MUST EMIT `hostname`, not just `host`.
#
# Alertmanager's route groups on [alertname, hostname] and both inhibit rules
# match with `equal: [hostname]`. A rule that only carries `host` -- which is
# what `sum by (host, ...)` yields, since that is the Loki stream label -- is
# therefore never suppressed by NodeDown for the same machine, and all of its
# instances collapse into a single group with an empty hostname. Alloy sets
# `host` and `hostname` identically, so aggregations here carry both.
{
  lib,
  pkgs,
  ...
}:
let
  yamlFormat = pkgs.formats.yaml { };

  # Decoder containers that emit a periodic liveness line.
  #
  # `pattern` null means "any log line at all" -- used for hfdlobserver, which
  # has no single stable heartbeat string but logs continuously.
  #
  # `window` defaults to 20m, which suits the five-minute heartbeat that the
  # acarsdec/dumpvdl2/dumphfdl containers emit (over a 48h sample it arrived 575
  # times out of 576, so 20m is ~4 missed beats). dump978 is on a different
  # mechanism with a 30 minute cadence and overrides it.
  #
  # These rules are traffic-independent by construction: they check that the
  # heartbeat line exists, not what value it carries. A receiver sitting on a
  # genuinely silent frequency still emits its heartbeat, so no quiet-hours
  # scoping is needed here. Scoping only matters for throughput rules, which are
  # deliberately not in this file yet -- see the Phase 6 baselines.
  #
  # This list must track the services.adsb.containers definitions in
  # hosts/linux/*/configuration.nix.
  decoderUnits = [
    {
      host = "acarshub";
      unit = "docker-acarsdec-1.service";
      pattern = "\\[STATS\\] Total in the last";
    }
    {
      host = "acarshub";
      unit = "docker-acarsdec-2.service";
      pattern = "\\[STATS\\] Total in the last";
    }
    {
      # xng replaced acarsdec-3 on this receiver. It emits no periodic stats
      # line at all -- 6h of logs contained zero STATS-style output -- so the
      # only available liveness signal is "logging anything", as with
      # hfdlobserver.
      #
      # That makes this rule traffic-dependent, unlike every other entry here.
      # It is acceptable because xng covers 16 ACARS channels including busy
      # ones: over a 48h sample the quietest hour still produced 117 lines,
      # roughly two per minute. The 45m window is well beyond any plausible
      # lull while still catching a wedged container within an hour.
      host = "acarshub";
      unit = "docker-xng.service";
      pattern = null;
      window = "45m";
      trafficDependent = true;
    }
    {
      host = "vdlmhub";
      unit = "docker-dumpvdl2-1.service";
      pattern = "\\[STATS\\] Total in the last";
    }
    {
      host = "vdlmhub";
      unit = "docker-dumpvdl2-2.service";
      pattern = "\\[STATS\\] Total in the last";
    }
    {
      host = "vdlmhub";
      unit = "docker-dumpvdl2-3.service";
      pattern = "\\[STATS\\] Total in the last";
    }
    {
      host = "vdlmhub";
      unit = "docker-dumpvdl2-4.service";
      pattern = "\\[STATS\\] Total in the last";
    }
    {
      host = "hfdlhub1";
      unit = "docker-dumphfdl-1.service";
      pattern = "hfdl messages received in last";
    }
    {
      host = "hfdlhub1";
      unit = "docker-dumphfdl-2.service";
      pattern = "hfdl messages received in last";
    }
    {
      host = "hfdlhub1";
      unit = "docker-dumphfdl-3.service";
      pattern = "hfdl messages received in last";
    }
    {
      host = "hfdlhub2";
      unit = "docker-hfdlobserver.service";
      pattern = null;
    }
    {
      # dump978 has no decoder stats line. Its liveness signal is the built-in
      # message monitor, which logs every 30 minutes -- verified emitting
      # 10-13 lines in every one of the 24 hours across a 5 day sample, so it
      # is genuinely round-the-clock and its absence means the container is
      # wedged rather than the band being quiet.
      #
      # 90m is three missed runs. Anything tighter would false-positive on a
      # single skipped cycle.
      host = "sdrhub";
      unit = "docker-dump978.service";
      pattern = "\\[message-monitor\\]";
      window = "90m";
    }
  ];

  # absent_over_time returns 1 only when the selector matched nothing in the
  # window, and carries the selector's labels through, so each unit needs its
  # own rule to be individually identifiable.
  heartbeatRules = map (
    d:
    let
      window = d.window or "20m";
    in
    {
      alert = "DecoderHeartbeatMissing";
      expr =
        if d.pattern == null then
          ''absent_over_time({host="${d.host}", unit="${d.unit}"}[${window}])''
        else
          ''absent_over_time({host="${d.host}", unit="${d.unit}"} |~ `${d.pattern}` [${window}])'';
      for = "5m";
      labels = {
        severity = "critical";
        inherit (d) host unit;
        # Alertmanager groups on and inhibits by `hostname`, not `host`, so a
        # rule carrying only `host` is never suppressed by NodeDown for the
        # same machine and groups across hosts. Alloy sets both labels to the
        # same value, so this is simply the name Alertmanager expects.
        hostname = d.host;
      };
      annotations = {
        summary = "Decoder ${d.unit} on ${d.host} has stopped logging";
        description =
          "No heartbeat line for ${window}. The container is running but wedged, or its journal has stopped reaching Loki. "
          + (
            if d.trafficDependent or false then
              "This decoder emits no periodic heartbeat, so the signal is any log line at all: an exceptionally quiet band could in principle produce this alert without the container being broken."
            else
              "This is independent of how much traffic the receiver should be decoding, so it is not a quiet-band false positive."
          );
      };
    }
  ) decoderUnits;

  # Hosts that ship journal logs to Loki. Desktops are excluded: maranello
  # runs no Alloy, and Daytona is a roaming laptop that is legitimately
  # offline for long stretches.
  loggingHosts = [
    "sdrhub"
    "fredhub"
    "fredvps"
    "acarshub"
    "vdlmhub"
    "hfdlhub1"
    "hfdlhub2"

    # DEPLOY ORDER MATTERS: HostLogsMissing fires 40 minutes after this list
    # names a host that is not shipping. nvrhub must be deployed (and its
    # Alloy running) BEFORE sdrhub picks up this rule set, or the master
    # alerts on a host that has never existed. Deploy nvrhub first, sdrhub
    # second.
    "nvrhub"
  ];

  # Per-host log-shipping deadman. Prometheus cannot express this: the
  # distributor's ingestion counter is labelled by tenant only, with no
  # per-source dimension. Here the host label exists on the stream itself.
  hostLogRules = map (h: {
    alert = "HostLogsMissing";
    expr = ''absent_over_time({host="${h}"}[30m])'';
    for = "10m";
    labels = {
      severity = "warning";
      host = h;
      hostname = h;
    };
    annotations = {
      summary = "No logs received from ${h} for 30 minutes";
      description = "Alloy on ${h} has stopped shipping, or the host is unreachable. Every log-derived alert for this host is silently inoperative until it returns.";
    };
  }) loggingHosts;

  rules = {
    groups = [
      {
        name = "decoder-liveness";
        interval = "1m";
        rules = heartbeatRules;
      }

      {
        name = "log-shipping-liveness";
        interval = "1m";
        rules = hostLogRules;
      }

      {
        name = "decoder-process-health";
        interval = "1m";
        rules = [
          {
            # Emitted by the SDRE base image's s6wrap for any supervised
            # program that dies. The only signal that is consistent across
            # the whole container family, and it covers dumphfdl and
            # hfdlobserver, neither of which ships a HEALTHCHECK.
            #
            # `sdrplay` is excluded from the prefix match. The SDRplay vendor
            # daemon (sdrplay_apiService) segfaults during its own teardown
            # whenever it is stopped while a decoder still holds a device
            # handle, so every container restart produced a CAUTION line and
            # a critical page. That is a shutdown artefact, not a decoder
            # crash: the decoder in question came back and resumed
            # normally. The real bug is fixed in docker-dumphfdl (the
            # decoder now execs so s6 supervises it directly, instead of
            # reporting "successfully stopped" while it is still running),
            # but the vendor daemon will segfault again for anyone else who
            # kills it with a client attached, so the exclusion stays.
            #
            # A decoder death still pages, because those lines carry the
            # decoder's own prefix (`[dumphfdl]`, `[hfdlobserver]`, ...).
            # This narrows the match; it does not disable the alert.
            alert = "SDRDecoderCrashed";
            expr = ''sum by (host, hostname, unit) (count_over_time({unit=~"docker-.*"} |= `[s6wrap] !!! CAUTION !!!` != `[sdrplay] [s6wrap]` [15m])) > 0'';
            for = "0m";
            labels.severity = "critical";
            annotations = {
              summary = "Decoder process crashed in {{ $labels.unit }} on {{ $labels.host }}";
              description = "s6wrap reported a supervised program terminating on a signal in the last 15 minutes. The SDRplay API daemon is excluded -- it segfaults on teardown by design flaw, see the rule comment.";
            };
          }

          {
            # hfdlobserver supervises its own children and reports their exit
            # status itself. Exit 0 is routine rotation; negative values are
            # signal deaths. Threshold allows for occasional restarts.
            alert = "HFDLObserverChildCrashing";
            expr = ''sum by (host, hostname, unit) (count_over_time({unit="docker-hfdlobserver.service"} |~ `exited with -(11|6|9)` [30m])) > 2'';
            for = "5m";
            labels.severity = "warning";
            annotations = {
              summary = "hfdlobserver child processes crashing on {{ $labels.host }}";
              description = "More than two signal deaths of IQDecoderProcess or KiwiClientProcess in 30 minutes.";
            };
          }
        ];
      }

      {
        name = "sdr-hardware";
        interval = "1m";
        rules = [
          {
            alert = "SDRCannotClaimDevice";
            expr = ''sum by (host, hostname, unit) (count_over_time({unit=~"docker-.*"} |= `usb_claim_interface error` [30m])) > 10'';
            for = "10m";
            labels.severity = "critical";
            annotations = {
              summary = "{{ $labels.unit }} on {{ $labels.host }} cannot claim its SDR";
              description = "Repeated usb_claim_interface failures. The device is held by another process, has disappeared from the bus, or is resetting.";
            };
          }

          {
            # Symptom of the global usbfs ceiling being exhausted. Expected to
            # fire on vdlmhub until the usbfs kernel parameter is deployed --
            # see modules/hardware/usbfs.nix.
            alert = "SDRUsbfsBufferExhausted";
            expr = ''sum by (host, hostname, unit) (count_over_time({unit=~"docker-.*"} |~ `(Failed to submit transfer|async read failed)` [15m])) > 5'';
            for = "5m";
            labels.severity = "warning";
            annotations = {
              summary = "USB transfer failures in {{ $labels.unit }} on {{ $labels.host }}";
              description = "librtlsdr could not submit USB transfers. Usually the usbcore.usbfs_memory_mb ceiling is too low for the number of attached radios.";
            };
          }

          {
            # `ReleaseDevice` is excluded deliberately. The API daemon being
            # gone while a decoder releases its device is the *shutdown*
            # path: s6-rc stops the sdrplay service, the vendor daemon
            # segfaults on teardown, and the decoder's ReleaseDevice() then
            # finds nothing listening and throws. Every container restart
            # therefore produced a critical page for a decoder that was
            # about to come back healthy.
            #
            # What remains is the case the alert is actually named for: a
            # decoder that cannot *acquire* its radio because the daemon is
            # not answering. That is genuinely unrecoverable without
            # intervention, which is why it stays critical.
            #
            # Note the annotation used to claim "cannot acquire its radio"
            # while matching the release path -- it described the opposite
            # of what had happened, which is worse than not alerting during
            # triage.
            alert = "SDRPlayApiUnresponsive";
            expr = ''sum by (host, hostname, unit) (count_over_time({unit=~"docker-.*"} |= `sdrplay_api_ServiceNotResponding` != `ReleaseDevice` [30m])) > 0'';
            for = "0m";
            labels.severity = "critical";
            annotations = {
              summary = "SDRplay API unresponsive on {{ $labels.host }}";
              description = "sdrplay_apiService is not answering a device-acquire call. The decoder in {{ $labels.unit }} cannot start until the service is restarted. Release-path failures during container shutdown are excluded -- see the rule comment.";
            };
          }

          {
            # The dump978 image restarts its own decoder when it sees no
            # messages, and alerting on that rather than on the staleness
            # warning gets quiet-hours scoping for free: the container only
            # restarts inside its own 0800-1800 "Adjustment Timeframe", and
            # outside it logs "No action is taken" instead. Verified over a 5
            # day sample -- "Restarting the" appears only in hours 08-17, and
            # the no-action line only in 00-07 and 18-23, an exact complement.
            # So this fires only during hours when UAT traffic is expected,
            # with no time functions in the query.
            #
            # Was running at roughly twenty restarts a day, caused by the
            # receiver being unable to claim its device. After the usbfs
            # ceiling fix: 0 restarts in 12h, against 54 in the preceding 3
            # days, and the monitor now reports OK more often than stale.
            alert = "ContainerSelfRestartingReceiver";
            expr = ''sum by (host, hostname, unit) (count_over_time({unit=~"docker-.*"} |= `[message-monitor]` |= `Restarting the` [2h])) > 3'';
            for = "10m";
            labels.severity = "warning";
            annotations = {
              summary = "{{ $labels.unit }} on {{ $labels.host }} keeps restarting its own receiver";
              description = "The container's built-in message monitor has restarted the decoder more than three times in two hours. Either the receiver is failing or the container's staleness threshold is wrong for this site.";
            };
          }
        ];
      }

      {
        name = "feeder-connectivity";
        interval = "1m";
        rules = [
          {
            alert = "MlatNotSynchronized";
            expr = ''sum by (host, hostname, unit) (count_over_time({unit=~"docker-.*"} |~ `Server status: +(not synchronized|clock unstable)` [30m])) > 0'';
            for = "10m";
            labels.severity = "warning";
            annotations = {
              summary = "MLAT not synchronized on {{ $labels.host }}";
              description = "mlat-client reports no synchronization with nearby receivers, or an unstable clock, in {{ $labels.unit }}.";
            };
          }

          {
            alert = "FeederUpstreamRetrying";
            expr = ''sum by (host, hostname, unit) (count_over_time({unit=~"docker-.*"} |= `Connection retries will continue` [30m])) > 2'';
            for = "10m";
            labels.severity = "warning";
            annotations = {
              summary = "Feeder upstream unreachable from {{ $labels.unit }} on {{ $labels.host }}";
              description = "Repeated connection retries to an upstream aggregator.";
            };
          }

          {
            # Matches on the module path, not the log level. In acars_router
            # sdre_stubborn_io indicates genuine connectivity loss, whereas
            # message_handler errors are malformed upstream JSON and are noise.
            alert = "AcarsRouterUpstreamFlapping";
            expr = ''sum by (host, hostname, unit) (count_over_time({unit=~"docker-.*"} |~ `sdre_stubborn_io.*(Disconnect occurred|Write while disconnected)` [30m])) > 20'';
            for = "15m";
            labels.severity = "warning";
            annotations = {
              summary = "acars_router upstream connection flapping on {{ $labels.host }}";
              description = "Sustained disconnect or back-pressure events against an upstream feed from {{ $labels.unit }}.";
            };
          }
        ];
      }

      {
        # Recording rules only. These build the history that the seasonal
        # baseline alerts need; they do not alert on their own. The
        # comparison rules cannot be written until roughly three weeks of
        # this series exists -- see agent-docs/MONITORING.md, Phase 6.
        name = "decoder-throughput-recording";
        interval = "1m";
        # NOTE: xng on acarshub is deliberately absent from these rules. It
        # emits no periodic stats line, so there is no count to unwrap; the
        # only way to derive throughput would be to count individual decoded
        # message lines, which is a different and much more expensive query
        # shape than `last_over_time` on a pre-aggregated total. Its liveness
        # is covered by the decoder-liveness group instead.
        rules = [
          {
            record = "decoder:messages:last5m";
            expr = ''sum by (host, hostname, unit) (last_over_time({unit=~"docker-(acarsdec|dumpvdl2)-.*"} | regexp `Total in the last \d+ minutes: (?P<msgs>\d+)` | unwrap msgs [10m]))'';
          }
          {
            record = "decoder:messages:last5m";
            expr = ''sum by (host, hostname, unit) (last_over_time({unit=~"docker-dumphfdl-.*"} | regexp `(?P<msgs>\d+) hfdl messages received` | unwrap msgs [10m]))'';
          }
        ];
      }
    ];
  };

  ruleFile = yamlFormat.generate "decoder-logs.yaml" rules;

  # Loki's local ruler storage expects <directory>/<tenant>/<file>.yaml.
  # auth_enabled is false, so the tenant is "fake" -- confirmed by the
  # on-disk layout at /var/lib/loki/chunks/fake.
  rulesDir = pkgs.runCommand "loki-rules" { } ''
    mkdir -p "$out/fake"
    cp ${ruleFile} "$out/fake/decoder-logs.yaml"
  '';
in
{
  # Exposed so `checks.decoder-units-sync` can compare this list against the
  # actual `services.adsb.containers` on each host. The list drifted once
  # already: acarsdec-3 was replaced by xng on acarshub and the stale entry
  # kept firing DecoderHeartbeatMissing for a container that no longer
  # existed. A comment saying "this list must track the host configs" is not
  # an enforcement mechanism.
  options.monitoring.decoderUnits = lib.mkOption {
    type = lib.types.listOf lib.types.attrs;
    internal = true;
    readOnly = true;
    default = decoderUnits;
    description = "Decoder units covered by heartbeat rules, read by the decoder-units-sync flake check.";
  };

  config = {
    # The ruler needs a writable scratch directory for rule evaluation state.
    systemd.tmpfiles.rules = [
      "d /var/lib/loki/rules-temp 0750 loki loki -"
    ];

    services.loki.configuration.ruler = {
      storage = {
        type = "local";
        local.directory = "${rulesDir}";
      };

      rule_path = "/var/lib/loki/rules-temp";

      alertmanager_url = "http://127.0.0.1:9093";
      enable_alertmanager_v2 = true;

      # Single-binary deployment; no ring coordination needed.
      ring.kvstore.store = "inmemory";

      # Recording rule output is pushed into Prometheus, which already runs with
      # --web.enable-remote-write-receiver (see prometheus.nix extraFlags).
      remote_write = {
        enabled = true;
        clients.prometheus = {
          url = "http://127.0.0.1:9090/api/v1/write";
          remote_timeout = "30s";
          queue_config = {
            capacity = 2500;
            max_shards = 10;
            min_shards = 1;
          };
        };
      };
    };

    # Keep the generated rule file inspectable on the host for debugging.
    environment.etc."loki/rules/decoder-logs.yaml".source = ruleFile;
  };
}
