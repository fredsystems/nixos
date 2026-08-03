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
{
  pkgs,
  ...
}:
let
  yamlFormat = pkgs.formats.yaml { };

  # Decoder containers that emit a periodic liveness line. The heartbeat
  # cadence is five minutes, and over a 48h sample it arrived 575 times out of
  # 576, so a 20 minute absence window is ~4 missed beats and is not noisy.
  #
  # `pattern` null means "any log line at all" -- used for hfdlobserver, which
  # has no single stable heartbeat string but logs continuously.
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
      host = "acarshub";
      unit = "docker-acarsdec-3.service";
      pattern = "\\[STATS\\] Total in the last";
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
  ];

  # absent_over_time returns 1 only when the selector matched nothing in the
  # window, and carries the selector's labels through, so each unit needs its
  # own rule to be individually identifiable.
  heartbeatRules = map (d: {
    alert = "DecoderHeartbeatMissing";
    expr =
      if d.pattern == null then
        ''absent_over_time({host="${d.host}", unit="${d.unit}"}[20m])''
      else
        ''absent_over_time({host="${d.host}", unit="${d.unit}"} |~ `${d.pattern}` [20m])'';
    for = "5m";
    labels = {
      severity = "critical";
      inherit (d) host unit;
    };
    annotations = {
      summary = "Decoder ${d.unit} on ${d.host} has stopped logging";
      description = "No heartbeat line for 20 minutes. The container is running but wedged, or its journal has stopped reaching Loki. This is independent of how much traffic the receiver should be decoding.";
    };
  }) decoderUnits;

  rules = {
    groups = [
      {
        name = "decoder-liveness";
        interval = "1m";
        rules = heartbeatRules;
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
            alert = "SDRDecoderCrashed";
            expr = ''sum by (host, unit) (count_over_time({unit=~"docker-.*"} |= `[s6wrap] !!! CAUTION !!!` [15m])) > 0'';
            for = "0m";
            labels.severity = "critical";
            annotations = {
              summary = "Decoder process crashed in {{ $labels.unit }} on {{ $labels.host }}";
              description = "s6wrap reported a supervised program terminating on a signal in the last 15 minutes.";
            };
          }

          {
            # hfdlobserver supervises its own children and reports their exit
            # status itself. Exit 0 is routine rotation; negative values are
            # signal deaths. Threshold allows for occasional restarts.
            alert = "HFDLObserverChildCrashing";
            expr = ''sum by (host, unit) (count_over_time({unit="docker-hfdlobserver.service"} |~ `exited with -(11|6|9)` [30m])) > 2'';
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
            expr = ''sum by (host, unit) (count_over_time({unit=~"docker-.*"} |= `usb_claim_interface error` [30m])) > 10'';
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
            expr = ''sum by (host, unit) (count_over_time({unit=~"docker-.*"} |~ `(Failed to submit transfer|async read failed)` [15m])) > 5'';
            for = "5m";
            labels.severity = "warning";
            annotations = {
              summary = "USB transfer failures in {{ $labels.unit }} on {{ $labels.host }}";
              description = "librtlsdr could not submit USB transfers. Usually the usbcore.usbfs_memory_mb ceiling is too low for the number of attached radios.";
            };
          }

          {
            alert = "SDRPlayApiUnresponsive";
            expr = ''sum by (host, unit) (count_over_time({unit=~"docker-.*"} |= `sdrplay_api_ServiceNotResponding` [30m])) > 0'';
            for = "0m";
            labels.severity = "critical";
            annotations = {
              summary = "SDRplay API unresponsive on {{ $labels.host }}";
              description = "sdrplay_apiService is not answering. The decoder in {{ $labels.unit }} cannot acquire its radio until the service is restarted.";
            };
          }

          {
            # The dump978 image restarts its own decoder when it sees no
            # messages. At this site UAT is genuinely quiet, so it has been
            # bouncing the decoder roughly twenty times a day. Alert on the
            # container giving up rather than on the staleness warning.
            alert = "ContainerSelfRestartingReceiver";
            expr = ''sum by (host, unit) (count_over_time({unit=~"docker-.*"} |= `[message-monitor]` |= `Restarting the` [2h])) > 3'';
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
            expr = ''sum by (host, unit) (count_over_time({unit=~"docker-.*"} |~ `Server status: +(not synchronized|clock unstable)` [30m])) > 0'';
            for = "10m";
            labels.severity = "warning";
            annotations = {
              summary = "MLAT not synchronized on {{ $labels.host }}";
              description = "mlat-client reports no synchronization with nearby receivers, or an unstable clock, in {{ $labels.unit }}.";
            };
          }

          {
            alert = "FeederUpstreamRetrying";
            expr = ''sum by (host, unit) (count_over_time({unit=~"docker-.*"} |= `Connection retries will continue` [30m])) > 2'';
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
            expr = ''sum by (host, unit) (count_over_time({unit=~"docker-.*"} |~ `sdre_stubborn_io.*(Disconnect occurred|Write while disconnected)` [30m])) > 20'';
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
        rules = [
          {
            record = "decoder:messages:last5m";
            expr = ''sum by (host, unit) (last_over_time({unit=~"docker-(acarsdec|dumpvdl2)-.*"} | regexp `Total in the last \d+ minutes: (?P<msgs>\d+)` | unwrap msgs [10m]))'';
          }
          {
            record = "decoder:messages:last5m";
            expr = ''sum by (host, unit) (last_over_time({unit=~"docker-dumphfdl-.*"} | regexp `(?P<msgs>\d+) hfdl messages received` | unwrap msgs [10m]))'';
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
}
