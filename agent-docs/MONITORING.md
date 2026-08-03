# Monitoring and Alerting

Reference for the Prometheus / Alertmanager / Loki / Grafana stack, the SDR container signal catalogue, and the open work required to make alerting on the decoder fleet trustworthy.

## How to use this document

This is a living reference, not a changelog. Three kinds of content live here:

- **Reference** -- how the stack is wired, what signals exist, what they mean.
- **Verified defects** -- concrete bugs found by querying the live stack, each with evidence and a checkbox.
- **Work plan** -- phased tasks with checkboxes.

### Deployment status

A ticked checkbox in this document means **the code is committed and verified by
eval, promtool and live query -- not that it is running in production.** The
work landed on the `fix/monitoring-alerting-overhaul` branch; nothing has been
applied to the fleet yet.

Deployed and verified in production:

- **usbfs ceiling** raised to 1000 MB on the four hosts with USB radios. This
  resolved two long-standing faults: `usb_claim_interface error` on dump978
  (37,948 events in 7 days, now zero) and `Failed to submit transfer` on
  vdlmhub (2,095 events, now zero).
- **smartctl exporter** on all six SMART-capable hosts, 20 metrics each.
  sdrhub's Lexar NM620 reports 54% of rated write endurance consumed after
  37.8 TB written -- the finding that justified adding it. Below the 80%
  warning threshold, so it does not alert yet.
- **blackbox exporter** probing 20 endpoints, 14 TLS certificates, minimum
  headroom 49 days, zero failing probes.
- **Pushover** replaced ntfy; `alertmanager-ntfy` removed from the critical
  path. Critical alerts use emergency priority and re-alert until
  acknowledged.
- **Deadman** pings healthchecks.io every 2 minutes. Schedule: **period 5m,
  grace 10m**, giving ~15 minutes to detect total alerting failure.

  The 2-minute cadence is not a typo for 1 minute. Alertmanager only
  re-evaluates whether to notify on each `group_interval` tick, and its dedup
  stage sends only when `lastNotify < now - repeat_interval`. With
  `repeat_interval` equal to `group_interval`, the tick at exactly one interval
  fails that test by a hair and slips to the next tick, so any
  `repeat_interval >= group_interval` yields a real cadence of
  `2 x group_interval`. Confirmed against the ping log: 09:25, 09:27, 09:29.

  Grace is 10m rather than 5m so a reboot of sdrhub (1-3 minutes) does not
  trip it. For planned maintenance longer than ~15 minutes, pause the check in
  the healthchecks.io UI rather than widening the window permanently -- a
  deadman with a 25-hour detection time is decoration.

A trap worth knowing about, since it will recur on any new host: the nixpkgs
smartctl module's udev rule is gated on `ACTION=="add"`, so it fires at boot
and never again. Deploying the exporter to a running system leaves
`/dev/nvme0` as `crw------- root root`, and the exporter serves
`smartctl_devices 1` with no device metrics while its scrape target still
reports up. Capabilities do not help -- the unit has CAP_SYS_RAWIO and
CAP_SYS_ADMIN, and neither bypasses DAC. `modules/monitoring/agent/smartctl.nix`
applies the ACL explicitly via a oneshot ordered before the exporter.

### Maintenance rules

- Tick a checkbox when the change is committed and verified by eval, promtool
  and live query. Note separately if it has not yet been deployed.
- When a defect is fixed, leave the entry with its box ticked. The evidence is why the fix exists.
- If a claim here is contradicted by the live stack, re-verify with the commands in [Verification commands](#verification-commands) and correct the document in the same commit as the code change.

**Important for agents:** every defect in this document was found by querying the running Prometheus and Loki instances, not by reading the Nix code. Prior review passes that reasoned only from source missed all of them, because the failure mode is consistently "the config is syntactically fine and refers to a metric that does not exist." Reason from the live stack.

## Stack topology

### Component placement

| Host      | Role              | node_exp | cAdvisor | Alloy | Prometheus | Alertmanager | Grafana | Loki |
| --------- | ----------------- | -------- | -------- | ----- | ---------- | ------------ | ------- | ---- |
| sdrhub    | monitoring-master | yes      | yes      | yes   | yes        | yes          | yes     | yes  |
| fredhub   | monitoring-agent  | yes      | yes      | yes   | no         | no           | no      | no   |
| fredvps   | monitoring-agent  | yes      | yes      | yes   | no         | no           | no      | no   |
| acarshub  | monitoring-agent  | yes      | yes      | yes   | no         | no           | no      | no   |
| vdlmhub   | monitoring-agent  | yes      | yes      | yes   | no         | no           | no      | no   |
| hfdlhub1  | monitoring-agent  | yes      | yes      | yes   | no         | no           | no      | no   |
| hfdlhub2  | monitoring-agent  | yes      | yes      | yes   | no         | no           | no      | no   |
| maranello | desktop           | yes      | no       | no    | no         | no           | no      | no   |
| Daytona   | desktop           | yes      | no       | yes   | no         | no           | no      | no   |

Daytona is excluded from pull-based scraping at `modules/monitoring/master/prometheus.nix:13` and instead pushes via `prometheus.remote_write` and `loki.write` from a bespoke Alloy config at `hosts/linux/daytona/configuration.nix:51-134`.

Versions in use: Prometheus 3.12.0, Alertmanager 0.31.1, Loki 3.7.4, Alloy 1.16.0. Prometheus retention 90d, Loki retention 30d.

sdrhub additionally runs the Loki ruler (29 rules across 6 groups) and a blackbox exporter; every agent runs a smartctl exporter.

### Scrape configuration

Defined at `modules/monitoring/master/prometheus.nix:160-262`. Global `scrape_interval` and `evaluation_interval` are both 15s.

14 jobs, 49 targets, all healthy. The blackbox and smartctl jobs are defined by
their own modules rather than here: `scrapeConfigs` and `ruleFiles` are both
`listOf` options that merge across modules, so an exporter can be self-contained.

| Job                     | Targets                                   | Labels attached          |
| ----------------------- | ----------------------------------------- | ------------------------ |
| node                    | all agents + desktops + sdrhub on :9100   | hostname, role, exporter |
| cadvisor                | all agents + sdrhub on :4567 (7)          | hostname, role, exporter |
| smartctl                | 6 SMART-capable hosts on :9633            | hostname, role, exporter |
| ultrafeeder             | sdrhub.local:9274                         | hostname, role           |
| acarshub                | sdrhub.local:8085                         | hostname, role           |
| prometheus              | 127.0.0.1:9090                            | hostname, role           |
| alertmanager            | 127.0.0.1:9093                            | hostname, role           |
| loki                    | 127.0.0.1:5678                            | hostname, role           |
| grafana                 | 127.0.0.1:3333                            | hostname, role           |
| pushgateway             | 127.0.0.1:9091 (honor_labels)             | hostname, role           |
| blackbox-exporter       | 127.0.0.1:9115 (the exporter itself)      | none                     |
| blackbox-https          | 3 public HTTPS endpoints, must be 2xx     | instance, job            |
| blackbox-https-redirect | 11 apex domains, must be 3xx              | instance, job            |
| blackbox-http-internal  | 6 internal vhosts via the nginx proxy     | instance, job            |

`dump978` was removed: nothing inside the container listens on the published
port 9275, so it was a permanently-down phantom target. Its metrics are served
by the container's own nginx, which currently 404s on `/metrics`.

Alertmanager routes by severity to three Pushover receivers, plus a `watchdog` receiver that pings healthchecks.io. Alertmanager, Grafana and Loki are all scraped. See [Notification transport](#notification-transport).

## Verified defects

### Dead alert rules

**All defects in this section are fixed.** They are retained because the evidence explains why the current shape is what it is, and because the failure mode recurs.

Five of the then-twenty-two rules referenced metrics with no active series. Prometheus reported all of them as `health=ok`, because a rule evaluating to an empty vector is considered healthy. They had never fired and could not fire. The rule set is now 49 alerts across 9 files, all covered by `promtool` unit tests and by `scripts/check-alert-metrics.sh`.

| Rule                    | Location             | Missing metric                                | Cause                                                     |
| ----------------------- | -------------------- | --------------------------------------------- | --------------------------------------------------------- |
| DockerUnitFlapping      | docker-rules.yaml:5  | node_systemd_unit_restart_total                | collector flag not passed to node_exporter                |
| SDRServiceFailure       | docker-rules.yaml:14 | promtail_custom_sdr_service_failure_total      | promtail replaced by Alloy, which uses unprefixed names   |
| FeederUpstreamFailure   | docker-rules.yaml:23 | promtail_custom_feeder_upstream_failure_total  | same as above                                             |
| UltrafeederNoAircraft   | sdr-alerts.yaml:5    | readsb_stats_aircraft_with_pos                 | exporter emits readsb_aircraft_* families instead         |
| UltrafeederNotReceiving | sdr-alerts.yaml:14   | readsb_stats_messages                          | same as above                                             |

`node_systemd_unit_restart_total` requires `--collector.systemd.enable-restarts-metrics`, which `modules/monitoring/agent/node_exporter.nix:278-287` does not pass.

- [x] Enable the systemd restarts collector, or rewrite `DockerUnitFlapping` against cAdvisor `container_start_time_seconds`
- [x] Delete `SDRServiceFailure` and `FeederUpstreamFailure`
- [x] Rewrite `sdr-alerts.yaml` against the metric families that actually exist

### PrometheusTargetDown cannot fire

`modules/monitoring/master/alert-rules/alert-rules.yaml:115`:

```promql
sum by (job, instance) (up{role!="desktop"} == 0) > 0
```

`== 0` filters to series valued zero. Summing zeros yields zero. `0 > 0` is false unconditionally. Verified live:

```text
up{role!="desktop"} == 0                               -> 2 series, value 0
sum by (job,instance) (up{role!="desktop"} == 0)       -> 2 series, value 0
sum by (job,instance) (up{role!="desktop"} == 0) > 0   -> EMPTY
count by (job,instance) (up{role!="desktop"} == 0) > 0 -> 2 series, value 1
```

The fix is `count` rather than `sum`.

- [x] Replace `sum` with `count` in `PrometheusTargetDown`

### Phantom scrape targets

`sdrhub.local:9273` and `sdrhub.local:9275` are permanently down. The containers are healthy and decoding normally -- nothing is listening on those ports inside the containers. Docker publishes them, `docker-proxy` accepts the connection, and the connection is then reset because there is no upstream listener.

```text
host:   LISTEN 0.0.0.0:9273 / 9274 / 9275        (docker-proxy)
curl 127.0.0.1:9273 -> Connection reset by peer
curl 127.0.0.1:9274 -> 200
curl 127.0.0.1:9275 -> Connection reset by peer

inside ultrafeeder: readsb on 31003-31006, 32006-32008, 30002-30003 -- nothing on 9273
inside dump978:     dump978-fa on 30978-30979, readsb on 37981/37982, nginx on 80 -- nothing on 9275
```

Ultrafeeder's exporter works on 9274 and emits `readsb_aircraft_*`, `readsb_messages_*`, `readsb_position_count_*`, and `readsb_signal_*`. The `readsb_stats_*` names used by the alert rules exist only in Loki's historical label index.

dump978 sets `ENABLE_PROMETHEUS=true` and `PROMETHEUSPORT=9275` but serves metrics through its internal nginx, which currently returns 404 for `/metrics` and logs `open() "/run/readsb/stats.prom" failed`. That is a container configuration problem, tracked separately below.

- [x] Remove the `sdrhub.local:9273` and `sdrhub.local:9275` targets
- [x] Repoint `sdr-alerts.yaml` at the `readsb_aircraft_*` and `readsb_messages_*` families served on 9274
- [ ] Decide whether dump978 metrics are wanted; if so fix the container's nginx metrics path

### Alloy metrics path

The log-to-metric pipeline in `modules/monitoring/agent/alloy.nix:59-84` is broken in three independent places, so fixing any one alone changes nothing.

```text
ss -lntp on sdrhub  -> LISTEN 127.0.0.1:12345
cmdline             -> alloy run /nix/store/...-agent.alloy   (no --server.http.listen-addr)
curl 127.0.0.1:12345/metrics     -> 200
curl 192.168.31.20:12345/metrics -> 000 (refused)
```

1. Alloy's HTTP listener binds localhost only, so `firewall.allowedTCPPorts = [ 12345 ]` at `alloy.nix:101-103` has no effect.
2. `prometheus.nix` defines no scrape job for Alloy.
3. The alert rules reference `promtail_custom_*`; Alloy emits the counters unprefixed.

This is orthogonal to log shipping, which works correctly on every host including Daytona. `loki.write` and `prometheus.remote_write` are outbound pushes and need no inbound listener; only a Prometheus pull from Alloy is blocked. The chosen resolution is to move rule evaluation into the Loki ruler and delete this block entirely rather than make Alloy scrapeable -- see [Decisions log](#decisions-log).

- [x] Delete the `loki.process "docker"` block and the port 12345 firewall opening from `alloy.nix`

### Smaller correctness defects

| Location                        | Defect                                                                                              |
| ------------------------------- | --------------------------------------------------------------------------------------------------- |
| system-alerts.yaml:5            | `NixOSNotOnMain` excludes `daytona`; the host is `Daytona` and the regex is case-sensitive          |
| sdr-alerts.yaml:9,18            | Annotations template `{{ $labels.hostname }}`; the ultrafeeder job attaches no `hostname` label     |
| prometheus.nix:161-193          | Jobs ultrafeeder, dump978, acarshub, prometheus, pushgateway attach no labels at all                |
| prometheus.nix:327              | Inhibit list references `SDRServiceFailure` and `FeederUpstreamFailure`, both being removed         |
| adsb-docker-units.nix:31-82     | `mkUnit` silently ignores the `hostname`, `requires`, and `depends_on` keys set by several hosts    |
| hardware/rtl-sdr.nix:17         | `lib.mkDefault` on a list option -- see [Kernel parameter merge hazard](#kernel-parameter-merge-hazard) |
| grafana.nix:74                  | `secret_key` hardcoded in plaintext; the admin password is correctly sops-managed                   |

- [x] Fix the `Daytona` regex case sensitivity
- [x] Add `hostname` and `role` labels to the unlabelled scrape jobs
- [x] Update the Alertmanager inhibit list when the dead rules are removed
- [ ] Either honour or remove the ignored keys in `mkUnit`
- [x] Remove `lib.mkDefault` from `boot.kernelParams` in `rtl-sdr.nix`
- [ ] Move the Grafana `secret_key` into sops

## Signal catalogue

The SDR containers are inconsistent about error reporting, and a generic match on `error` is worthless. The signals below are ordered by reliability.

### Throughput heartbeats

Every decoder emits a periodic, machine-parseable throughput line. Over a 48h sample these arrived 575 times out of 576 expected, so the **absence** of a heartbeat is itself a strong signal that a container has wedged, independent of the value it carries.

| Container family        | Log line                                                  | Period |
| ----------------------- | --------------------------------------------------------- | ------ |
| acarsdec-\*, dumpvdl2-\* | `[acars_bridge] [STATS] Total in the last 5 minutes: N`   | 5 min  |
| dumphfdl-\*             | `[hfdl_stats] N hfdl messages received in last 5 mins`    | 5 min  |
| ultrafeeder             | Prometheus exporter on :9274                              | scrape |

Extraction:

```logql
sum by (host, unit) (
  sum_over_time(
    {unit=~"docker-(acarsdec|dumpvdl2)-.*"}
      | regexp `Total in the last \d+ minutes: (?P<msgs>\d+)`
      | unwrap msgs [10m]
  )
)
```

### Process death

The SDRE base image is consistent about exactly one thing, `s6wrap`. This is the universal crash detector across the container family:

```text
[s6wrap] !!! CAUTION !!! Wrapped program terminated by signal: 11 (Segmentation fault)
[s6wrap] Command line for terminated program was: /usr/local/bin/dumphfdl --soapysdr driver=sdrplay,...
```

Observed over 7 days:

```text
2  hfdlhub1  docker-dumphfdl-1.service  dumphfdl              Segmentation fault
2  hfdlhub1  docker-dumphfdl-3.service  sdrplay_apiService    Segmentation fault
1  hfdlhub1  docker-dumphfdl-1.service  dumphfdl              Aborted
1  hfdlhub1  docker-dumphfdl-3.service  dumphfdl              Aborted
1  hfdlhub1  docker-dumphfdl-1.service  sdrplay_apiService    Segmentation fault
```

hfdlobserver logs its own equivalents: `IQDecoderProcess@web888-NN exited with -11`, `encountered unrecoverable error`, and the state line `web888-NN via ['KiwiClientProcess not running', 'IQDecoderProcess not running']`.

### Container healthchecks

The images ship their own `HEALTHCHECK` directives; cAdvisor already exports `container_health_state` with 391 series fleet-wide. Coverage is uneven and, critically, **inversely correlated with failure rate** -- every crash observed was `dumphfdl` or `hfdlobserver`, and neither ships a healthcheck.

```text
sdrhub     ultrafeeder dump978 acarshub acarshubv4 adsbhub degoog fr24
           opensky piaware planefinder planewatch radarvirtuel rbfeeder   = HC
           acars_router  acars2pos  sdrmap  dozzle  dozzle-agent          = none
acarshub   acarsdec-1/2/3                                                 = HC
vdlmhub    dumpvdl2-1/2/3/4                                               = HC
hfdlhub1   dumphfdl-1/2/3                                                 = none
hfdlhub2   hfdlobserver                                                   = none
```

Treat this as a fast supplementary signal at `warning` severity where it exists. It is not a backbone and must never be the only signal for a container.

### Curated error signatures

Only unambiguous patterns, explicitly enumerated. Never a generic level match.

| Pattern                                                   | Meaning                                   | Severity |
| --------------------------------------------------------- | ----------------------------------------- | -------- |
| `usb_claim_interface error`                               | cannot bind SDR (1219 hits, dump978)      | critical |
| `Failed to submit transfer` / `async read failed`         | usbfs ceiling exhausted (515/520, vdlmhub) | critical |
| `sdrplay_api_ServiceNotResponding`                        | SDRplay API service dead                  | critical |
| `Server status: (not synchronized\|clock unstable)`       | MLAT broken                               | warning  |
| `Connection retries will continue`                        | feeder upstream unreachable               | warning  |
| `Lost N packets ... on USB, MLAT could be UNSTABLE`       | USB or system clock issue                 | warning  |
| `sdre_stubborn_io.*(Disconnect occurred\|Write while disconnected)` | real upstream connection loss | warning  |
| `[message-monitor] [WARNING] Restarting the ... service`  | container gave up on its own receiver     | warning  |

For `acars_router` the discriminator is the **module path**, not the log level: `sdre_stubborn_io` indicates genuine connectivity loss, `message_handler` indicates data-quality noise.

### Signals deliberately ignored

Recording these so they are not "rediscovered" and added later.

| Pattern                                                | Why it is noise                                            |
| ------------------------------------------------------ | ---------------------------------------------------------- |
| `[R82XX] PLL not locked!`                              | normal during tuning                                       |
| `message_handler.*Failed to parse received message`    | malformed upstream JSON, not a container failure           |
| `acars2pos: failed distance check`                     | data quality filter working as designed                    |
| `collectd: rrd_update_r ... illegal attempt`           | rrdtool bookkeeping noise                                  |
| `Error response from daemon: No such container`        | emitted by our own `ExecStartPre` `docker rm -f`           |
| `readsb: UAT TCP input: Connection to dump978 refused` | symptom of dump978 restarting; alert on the cause instead  |
| `nginx: open() "/webapp/dist/favicon.ico" failed`      | cosmetic                                                   |

## Traffic seasonality

### Diurnal archetypes

Mean messages per five-minute heartbeat, by hour of day, sampled over seven days:

```text
receiver         0   1   2   3   4   5   6   7   8   9  10  11  12  13  14  15  16  17  18  19  20  21  22  23
acarsdec-1      17  10  14  12   8  13  17  23  24  30  28  32  31  20  26  25  20  22  22  18  20  26  17  17
acarsdec-2      10   7  11   5   4   6  10  14  26  16  21  19  20  14  17  20  17  14  16  12  17  22  14  14
acarsdec-3       0   0   0   0   0   0   0   0   0   0   0   1   0   0   0   0   0   0   0   0   0   0   0   0
dumphfdl-1       2   1   0   0   0   0   0   5   7   0   1   0   0   0   0   1   1   1   3   5  26  28  26  14
dumphfdl-2       0   0   1   1   1   0   0   0   0   0   0   0   0   0   0   0   0   0   0   0   0   0   0   0
dumphfdl-3       6  14  12  14   9   6  17  22  17  12   1   0   0   0   0   0   0   0   0   1   4   3   3   3
dumpvdl2-1      24  20  13   7   5   7  16  38  61  80  73  57  53  47  48  38  42  51  45  48  36  34  26  24
dumpvdl2-2      21  14   3   4   1  15  51  56  64  69  54  69  64  60  58  58  54  49  53  59  61  50  53  33
dumpvdl2-3       0   0   0   0   0   0   0   0   0   0   0   0   0   0   0   0   0   0   0   0   0   0   0   0
dumpvdl2-4       0   0   0   0   0   0   0   0   0   0   0   0   0   0   0   0   0   0   0   0   0   0   0   0
```

Three archetypes coexist in one fleet:

- **VHF aviation** (acarsdec-1/2, dumpvdl2-1/2) -- daytime curve, 08-12 peak, 03-05 trough, roughly fifteenfold swing.
- **HF propagation** (dumphfdl-1/3) -- inverted relative to VHF, and the two instances have nearly disjoint active windows. dumphfdl-1 peaks 20:00-23:00 and is dead 09:00-17:00; dumphfdl-3 peaks 01:00-08:00 and is dead 10:00-19:00. These windows drift with season, solar cycle, and scanner band selection.
- **Flat zero** (acarsdec-3, dumpvdl2-3/4, dumphfdl-2) -- expected, these sit on very quiet frequencies.

### Why fixed thresholds fail

Traffic varies by hour of day, day of week, season, weather, and holiday. Christmas is far quieter than Independence Day; overnight is quiet, and Sunday more so than Thursday. A flat "zero messages for 30m" rule would page continuously for the legitimately quiet receivers, and a threshold tuned for a busy receiver's daytime peak would miss a failure overnight.

A fixed per-receiver collection window is only marginally better, because the HF windows move. There is no static answer.

### Baseline strategies

Three complementary approaches, applied to different receiver classes.

**Self-baseline, same hour, prior weeks.** Handles diurnal shape and day-of-week for free, since a Sunday compares against prior Sundays:

```promql
  sum_over_time(decoder_msgs[1h])
    < 0.2 * avg_over_time(sum_over_time(decoder_msgs[1h])[3w:1w] offset 1w)
and
  avg_over_time(sum_over_time(decoder_msgs[1h])[3w:1w] offset 1w) > 5
```

The second clause is what makes quiet frequencies safe. If a receiver historically produced nothing at this hour, its baseline is near zero, the guard fails, and it never alerts. Averaging three weekly samples prevents one bad day from poisoning the baseline.

**Share of fleet volume.** Self-baselining still breaks on holidays, because the prior week was an ordinary week. Comparing a receiver's *share* of its group's total instead of its absolute volume removes that entirely: if all receivers drop together, every share holds steady and nothing fires; if one dies, its share collapses while its siblings' shares rise. No calendar knowledge required. This only holds within a homogeneous group, so it applies to acarsdec-1/2/3 and dumpvdl2-1/2/3/4 but not across the HF receivers with disjoint windows.

**Sibling comparison over a long window.** A self-baseline cannot detect a receiver that was already broken before the baseline window opened. Sibling comparison can -- dumphfdl-2 is flat zero across all 24 hours while both same-host, same-hardware siblings show clear propagation curves:

```promql
sum_over_time(decoder_msgs[7d])
  < 0.05 * quantile by (host) (0.5, sum_over_time(decoder_msgs[7d]))
```

Low severity, long window, `repeat_interval` measured in days. A prompt to inspect an antenna, not a page.

## USB and usbfs

### Why the ceiling is hit

librtlsdr pins roughly 3.75 MB per device (15 transfers of 256 KB). The kernel's global usbfs ceiling defaults to 16 MB:

```text
sdrhub    2 dongles ~  7.5 MB / 16 MB    fine
acarshub  3 dongles ~ 11.3 MB / 16 MB    borderline
vdlmhub   4 dongles ~ 15.0 MB / 16 MB    exhausted
```

This is the direct cause of the 515 `Failed to submit transfer` and 520 `async read failed` lines observed on vdlmhub over seven days, and vdlmhub is the only host producing them.

### usbfs_memory_mb semantics

From `drivers/usb/core/devio.c`:

```c
/* Limit on the total amount of memory we can allocate for transfers */
static u32 usbfs_memory_mb = 16;
module_param(usbfs_memory_mb, uint, 0644);
MODULE_PARM_DESC(usbfs_memory_mb,
    "maximum MB allowed for usbfs buffers (0 = no limit)");
```

Properties that matter:

- The default of 16 is a **compile-time constant**. It is not derived from RAM, chipset, USB controller, or CPU. Identical on a mini PC and on a large server.
- It is a **global, system-wide** cap shared by all usbfs users, not per-device or per-process.
- It is a **ceiling, not an allocation**. Raising it consumes no memory.
- `0` is documented as "no limit", implemented as the hard maximum of 2047 MB. The kernel parameter documentation reads `usbcore.usbfs_memory_mb= [USB] Memory limit (in MB) for buffers allocated by usbfs (default = 16, 0 = max = 2047)`. librtlsdr's suggestion to `echo 0` is therefore correct, not a bug -- we prefer an explicit bounded value for legibility.
- `module_param(..., 0644)` makes it writable at runtime through sysfs.

On every host in the fleet `usbcore` is **built into the kernel**, not a loadable module. `boot.extraModprobeConfig` is therefore a no-op, because `modprobe.d` only applies to modules that get loaded. The parameter has to come from the kernel command line.

### Kernel parameter merge hazard

`lib.mkDefault` on a list option does not merge -- a normal-priority definition wins outright and discards it. Verified with `lib.evalModules`:

```text
onlyMkDefault        -> [ "blacklist=dvb" ]
mkDefaultPlusNormal  -> [ "usbcore.usbfs_memory_mb=1000" ]     <- blacklist silently gone
bothNormal           -> [ "usbcore.usbfs_memory_mb=1000", "blacklist=dvb" ]
```

`modules/hardware/rtl-sdr.nix:17` sets `boot.kernelParams = lib.mkDefault [ "modprobe.blacklist=dvb_usb_rtl28xxu" ]`. If any other module sets `boot.kernelParams` at normal priority on the same host, that blacklist disappears silently. The `mkDefault` must be removed. This is currently latent, because `hardware-profile.rtl-sdr.enable` is set nowhere and `modules/hardware` is imported only by `profiles/desktop.nix`.

### USB topology

```text
vdlmhub   Bus001 root_hub 12p 480M -> external 4-port hub -> 4x RTL2838
acarshub  Bus001 root_hub 12p 480M -> external 4-port hub -> 3x RTL2838
hfdlhub1  Bus001 root_hub 12p 480M -> 3x SDRplay RSP1a directly on root ports
sdrhub    Bus003 root_hub 12p 480M -> external hub -> 2x RTL2832U   (4 buses total)
hfdlhub2  no USB SDR hardware -- hfdlobserver drives network web888/KiwiSDR receivers
```

Bandwidth is not the constraint:

```text
dumpvdl2  1.26 Msps x 2 bytes = 2.52 MB/s x 4 = ~10.1 MB/s
acarsdec  0.96 Msps x 2 bytes = 1.92 MB/s x 3 = ~ 5.8 MB/s
USB 2.0 practical ceiling                      = ~35-40 MB/s
```

At roughly a quarter of the available bus, the failure is purely the accounting ceiling.

### Consolidation guidance

Because the ceiling is machine-independent and global, **consolidating servers makes this worse, not better**. Twelve radios on one box need roughly 45 MB against the same 16 MB default -- a guaranteed failure on day one, on better hardware. The parameter is a prerequisite for any multi-dongle host, and grows more essential as hosts get denser.

What genuinely does depend on hardware: the number of independent USB host controllers (sdrhub exposes four buses, vdlmhub and acarshub two), whether radios are daisy-chained behind a single external hub (three of four hosts currently do this), and CPU available for demodulation. If consolidating, prefer multiple independent host controllers, avoid funnelling every radio through one hub, use powered hubs for bias-tee draw, and account for the RF and thermal cost of co-locating many dongles plus the concentration of the failure domain.

- [x] Add `modules/hardware/usbfs.nix` exposing `hardware-profile.usbfs.{enable,memoryMB}`
- [x] Enable it on sdrhub, acarshub, vdlmhub, hfdlhub1 -- **not** hfdlhub2, which has no USB radios
- [ ] Set `usbfs_memory_mb` proportionally if hosts are ever consolidated

## Tuning workflow

Thresholds cannot be derived from first principles. The deliverable is a tuning platform with defensible starting baselines, not a set of correct numbers.

- Alerts **fire immediately** rather than running in shadow mode, so real-time notifications provide the evidence for whether a threshold is right. See [Decisions log](#decisions-log).
- Severity routing lands **before** the throughput alerts, so tuning noise arrives at a different Pushover priority from `NodeDown`. Without it the channel that matters gets trained into background noise. Decoder throughput alerts are `info`, which is Pushover priority -1: delivered silently, no sound.
- Persist baselines as recording rules so a Grafana panel can show actual against baseline against threshold per receiver. Tuning then means reading a graph and changing one number.
- Keep thresholds in a Nix attrset, not inline in YAML, so a change is a one-line edit next to the container definition where the frequency list already lives.

## Notification transport

**Status: adopted.** ntfy and the `alertmanager-ntfy` bridge have been removed; alerts go to Pushover via Alertmanager's native receiver, and the deadman pings healthchecks.io. The evaluation below is retained because it records why, and which options were rejected.

### Current path and its gaps

For the record, the path this replaced: every severity went to a single `ntfy` receiver on one public topic at `high` priority, via the `alertmanager-ntfy` bridge on `127.0.0.1:8000`.

- Every severity shares one topic at one priority, so `FwupdUpdatesAvailable` (info, 24h) arrives as urgently as `NodeDown`. No transport change fixes this; it is a routing problem.
- No acknowledgement and no escalation. An unseen alert is simply lost.
- `alertmanager-ntfy` was a third-party bridge process in the critical path that nothing monitored. If it died the result was silence, which is indistinguishable from health. Removed.
- The topic was on **public ntfy.sh with no authentication**, and a ntfy topic name is effectively a password. Anyone who knew or guessed it could read hostnames, unit names and failure detail. Resolved by the migration: Pushover credentials live in sops.

### Constraints captured

- Phone is **iOS**. Rules out Gotify, whose iOS support is weak. Critical-alert delivery that bypasses Focus requires Pushover or the Home Assistant companion app.
- **Home Assistant is not in use and not wanted.** Do not propose it again.
- A one-time paid component is acceptable; Pushover's fee was explicitly approved in principle.
- Grafana OnCall OSS is **archived as of 2026-03-24** and its Cloud Connection for mobile push, SMS, and voice is disabled. It is not a candidate. Do not re-evaluate it.

### Delivery options evaluated

| Option             | Native in Alertmanager | Self-host | Bypasses iOS Focus | Ack or escalation      | Notes                                                            |
| ------------------ | ---------------------- | --------- | ------------------ | ---------------------- | ---------------------------------------------------------------- |
| Pushover           | yes, `pushover_configs` | no        | yes, emergency priority | retries until acked | Removes the bridge from the critical path entirely               |
| ntfy self-hosted   | needs bridge           | yes       | yes, priority 5    | no                     | Adds auth and private topics; keeps the existing bridge risk     |
| Telegram           | yes, `telegram_configs` | no        | no                 | no                     | Free, good formatting and search; buried among ordinary chats    |
| PagerDuty          | yes, `pagerduty_configs` | no      | yes, phone calls   | full escalation policies | Only option with true escalate-if-unacked; cloud dependency    |
| Gotify             | needs bridge           | yes       | no                 | no                     | Android-oriented; ruled out by the iOS constraint                |
| Email              | yes                    | yes       | no                 | no                     | Digest tier only                                                 |

### Triage and console options

| Option                          | Packaged as             | What it provides                                                                 |
| ------------------------------- | ----------------------- | -------------------------------------------------------------------------------- |
| Karma                           | `services.karma`        | Purpose-built Alertmanager console: grouped live state, silence management        |
| Grafana Alertmanager datasource | Grafana already running | Browse and silence alerts in an existing UI with no rule migration                |
| Alerta                          | `services.alerta`       | Alert database with deduplication, correlation, and history                       |
| Uptime Kuma                     | `services.uptime-kuma`  | Blackbox checks and deadman hosting rather than an Alertmanager console           |

All four are present in the pinned nixpkgs. Karma remains the recommended triage console and is not yet deployed.

### Deployed state

- Critical severity to **Pushover** at priority 2 (emergency): re-alerts until
  acknowledged and bypasses quiet hours, with `retry 2m` / `expire 1h` and the
  `siren` sound. This acknowledgement behaviour is the main reason for leaving
  ntfy -- an unseen critical was previously just lost.
- Warning to Pushover at priority 0, resolved notifications sent.
- Info to Pushover at priority -1 (silent, no sound), resolved notifications
  suppressed. This is the tier decoder throughput alerts land in while their
  thresholds are unproven.
- Notifications carry a tappable link to the alert's `GeneratorURL`, so tapping
  opens the Prometheus graph for that alert.
- Credentials via `token_file` / `user_key_file`, sourced from sops through
  `LoadCredential`. Alertmanager runs `DynamicUser=yes` so there is no stable
  uid for sops to chown to. Using the `_file` variants also preserves build-time
  `amtool` validation, which an envsubst placeholder would have forced off.
- Deadman pings healthchecks.io from the `watchdog` receiver.

**Alertmanager requires both `token` and `user_key`.** It calls
`api.pushover.net` directly rather than being a hosted "Pushover-powered
service", so it supplies the application identity as well as the recipient.
Pushover's own docs say "just supply your user key", but that addresses users of
a hosted service which already holds its own application token.

**Caveat worth remembering: `amtool check-config` does not validate notifier
templates.** An unterminated `{{ if }}` injected into the critical title was
accepted without complaint. The templates were therefore syntax-checked and
rendered separately against a representative alert group. Any future template
edit needs the same treatment.

Not yet deployed: **Karma** for triage, recommended on fredvps bound to
Tailscale rather than exposed publicly. Karma manages silences, so it is a
control plane, not a read-only view -- a bad actor could silence every alert.
Tailscale satisfies the off-LAN access requirement with no internet-facing
attack surface.

- [x] Decide whether to adopt this proposal
- [x] Independently of the above: move off the unauthenticated public ntfy.sh topic

## Work plan

### Phase 1 -- correctness

No tuning risk; all of these are outright bugs.

- [x] `PrometheusTargetDown`: `sum` to `count`
- [x] Drop the phantom 9273 and 9275 targets
- [x] Rewrite `sdr-alerts.yaml` against the families served on 9274
- [x] Delete `SDRServiceFailure` and `FeederUpstreamFailure`, update the inhibit list
- [x] Fix the `Daytona` regex case, add labels to unlabelled jobs
- [x] Add `modules/hardware/usbfs.nix` and enable on the four radio hosts
- [x] Remove `lib.mkDefault` from `boot.kernelParams` in `rtl-sdr.nix`

### Phase 2 -- severity routing

Prerequisite for anything noisy. Was implemented on ntfy first and carried over to Pushover unchanged, since the routing tree is transport-agnostic.

- [x] Route by severity (implemented on ntfy topics, now Pushover priorities)
- [x] Set a long `repeat_interval` for the tuning tier
- [x] Expand inhibit rules: docker daemon down suppresses container alerts; decoder crash suppresses its own throughput alert

### Phase 3 -- traffic-independent signals

Deployable immediately, nothing to tune.

- [x] Enable the Loki ruler with `remote_write` into Prometheus and Alertmanager wiring
- [x] Crash detection on `s6wrap` and `exited with -11`
- [x] Heartbeat-absence detection
- [x] `container_health_state != 1` at warning severity
- [x] Curated error signature rules from the catalogue above
- [x] Remove the dead `loki.process "docker"` block from `alloy.nix`

### Phase 4 -- monitoring stack resilience

The notification path was a single unmonitored point of failure: if Alertmanager or the delivery bridge died, silence was indistinguishable from health. Now monitored, and the deadman covers total failure.

- [x] Deadman's switch: always-firing alert to a separate receiver backed by an external heartbeat monitor
- [x] Scrape Alertmanager, Grafana, and Loki
- [x] Alert on `alertmanager_notifications_failed_total` and `prometheus_notifications_dropped_total`
- [x] Alert on `prometheus_rule_evaluation_failures_total`, `prometheus_tsdb_wal_corruptions_total`
- [x] Per-host log-ingestion deadman via `absent_over_time({host="X"}[15m])`
- [x] Alert on `docker.service` being down, to avoid a storm of downstream container alerts

### Phase 5 -- CI and container hygiene

- [x] `promtool test rules` wired into `flake/dev/checks.nix`
- [x] CI gate asserting every metric referenced in `alert-rules/*.yaml` returns a non-empty result
- [ ] `promtool check rules` in pre-commit
- [ ] Add `runbook_url` annotations to every alert
- [ ] Raise dump978's internal `message-monitor` threshold; it currently restarts its own decoder about 20 times a day because UAT is legitimately quiet at this site
- [x] Blackbox exporter for certificate expiry and external endpoint probes
- [x] Disk fill-rate prediction, systemd timer staleness, network errors, load saturation
- [x] smartctl exporter for SMART pre-failure attributes

### Phase 6 -- throughput baselines

Requires three weeks of recorded history before the `offset 1w` comparison is meaningful. Start recording in Phase 3 so history accumulates while earlier phases land.

- [x] Record `decoder_msgs` via the Loki ruler
- [ ] Self-baseline alerts once three weekly samples exist
- [ ] Share-of-fleet alerts for the homogeneous acarsdec and dumpvdl2 groups
- [ ] Sibling-comparison alerts at info severity

## Verification commands

Prometheus is at `192.168.31.20:9090`, Loki at `192.168.31.20:5678`. Both are reachable from the LAN without auth.

Check whether a rule's metrics actually exist:

```bash
curl -sG "http://192.168.31.20:9090/api/v1/query" \
  --data-urlencode 'query=count(node_systemd_unit_restart_total)'
```

List targets and their health:

```bash
curl -sG "http://192.168.31.20:9090/api/v1/targets?state=active" \
  | python3 -c "import json,sys; [print(t['labels']['job'], t['labels']['instance'], t['health'], t['lastError'][:60]) for t in json.load(sys.stdin)['data']['activeTargets']]"
```

List rule health, including rules that are silently empty:

```bash
curl -sG "http://192.168.31.20:9090/api/v1/rules" \
  | python3 -c "import json,sys; [print(g['name'], r['name'], r.get('health'), r.get('lastError','')) for g in json.load(sys.stdin)['data']['groups'] for r in g['rules']]"
```

Query container logs over a range:

```bash
curl -sG "http://192.168.31.20:5678/loki/api/v1/query_range" \
  --data-urlencode 'query={unit=~"docker-.*"} |~ `s6wrap`' \
  --data-urlencode "start=$(date -d '7 days ago' +%s)000000000" \
  --data-urlencode "end=$(date +%s)000000000" \
  --data-urlencode 'limit=1000'
```

Large regex alternations over a seven-day range will drop the Loki connection. Narrow the range to one or two days, or split the query.

## Decisions log

| Decision                                                     | Rationale                                                                                                                                     |
| ------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------- |
| Rules live in the Loki ruler, not Alloy `stage.metrics`      | One file on one host instead of a six-host colmena deploy per regex tweak. LogQL `unwrap` handles numeric heartbeat extraction, which `stage.metrics` cannot. Also removes the need for Alloy to be scrapeable. |
| Alerts fire immediately rather than running in shadow mode   | Real-time notifications give the evidence needed to judge whether a threshold is right. Requires severity routing first so tuning noise is isolated from critical alerts. |
| Throughput thresholds are relative, never absolute           | Traffic varies by hour, weekday, season, weather, and holiday, and the fleet contains three incompatible diurnal archetypes. No static threshold can be correct for all receivers. |
| `usbfs_memory_mb` set via `boot.kernelParams`                | `usbcore` is built into the kernel on all hosts, so `modprobe.d` options do not apply. A `systemd.tmpfiles` write is added alongside so the setting also takes effect without a reboot. |
| Explicit `1000` rather than `0`                              | `0` is valid and means the 2047 MB hard maximum, but a bounded value states intent and avoids an effectively unlimited pin budget.            |
| usbfs enabled on four hosts, not five                        | hfdlhub2 has no USB SDR hardware; hfdlobserver drives network web888/KiwiSDR receivers. It cannot go in `profiles/adsb-hub.nix`, which is also imported by fredvps, fredhub, and hfdlhub2. |
| Container healthchecks are a supplement, never a backbone    | Coverage is inversely correlated with failure rate -- the only containers observed crashing, dumphfdl and hfdlobserver, ship no healthcheck.  |
| Migrated ntfy to Pushover                                    | Acknowledgement was the deciding factor: Pushover priority 2 re-alerts until acked, so an unseen critical is not lost. Also removes the unmonitored `alertmanager-ntfy` bridge from the critical path and moves credentials into sops. |
| Grafana OnCall OSS excluded permanently                      | Archived 2026-03-24; Cloud Connection for mobile push, SMS, and voice is disabled. Recorded so it is not re-evaluated.                        |
