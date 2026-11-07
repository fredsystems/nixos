# Plan 02: ADS-B receiver comparison

- **Status:** planned
- **Branches:** none yet. This repo: `feat/receiver-comparison`. Tool:
  `fredsystems/beast-compare` (new repo).

## Goal

Measure, side by side and on the same transmissions, how well each 1090
receiver chain on the shared antenna performs, and in which conditions
each one wins: range, elevation, bearing, signal level, traffic density
and message type. The method takes any number of Beast sources from the
start. The first run is the Airspy against the FlightAware Pro Stick
Plus; the RTL-SDR Blog v3 and v4 join on acarshub and vdlmhub.

The expected result is that the Airspy wins nearly everywhere. The point
is to measure by how much, and where, with numbers that hold up, rather
than to rank on a 15-minute aircraft count.

## Superseded: the Airspy gain sweep

This plan was a gain sweep to choose a fixed `AIRSPY_ADSB_RF_GAIN`. That
goal is dropped, and `auto` stays:

- A fixed gain is right only for the RF chain and conditions it was
  measured in. When the Sawbird LNA went in ahead of the splitter on
  2026-11-07, `auto` moved from 20 to 9 on its own, while the RTL's stale
  gain (36.4 dB under the legacy autogain script) clipped it to zero
  reception for hours.
- The sweep's own outcome rule was already "keep `auto` unless a fixed
  gain clearly beats it".
- If `auto` is ever in doubt, it is one more pair of receivers in this
  method: run the Airspy at a fixed gain alongside, and compare. It needs
  no plan of its own.

The 2026-11-01 sweep's lessons carry over as design rules: hold every
control steady, measure per transmission rather than by set membership,
and never let time of day stand in for the variable under test.

## Receivers

| Receiver     | SDR                        | Host     | Decoder container            | Beast source (recorder view) |
| ------------ | -------------------------- | -------- | ---------------------------- | ---------------------------- |
| `airspy`     | Airspy R2, 20 MSPS         | sdrhub   | `airspy_adsb`                | `127.0.0.1:30105`            |
| `fa-proplus` | FlightAware Pro Stick Plus | sdrhub   | `tar1090_rtlsdr` (`00001090`) | `127.0.0.1:30106`            |
| `rtl-v3`     | RTL-SDR Blog v3            | acarshub | `tar1090_rtlv3` (`00001093`) | `acarshub.local:30005`       |
| `rtl-v4`     | RTL-SDR Blog v4            | vdlmhub  | `tar1090_rtlv4` (`00001094`) | `vdlmhub.local:30005`        |

All four sit on the four outputs of the LSA84 powered splitter (8 dB
amp, rated 54-1220 MHz), behind the Nooelec Sawbird 1090/UAT LNA.

## Decisions

| Topic                | Decision                                                                                                   |
| -------------------- | ---------------------------------------------------------------------------------------------------------- |
| Unit of comparison   | The individual transmission, matched across receivers. Not aircraft lists, not `aircraft.json` polling.    |
| Reference set        | The union of transmissions any receiver decoded. Rates are relative to it (see Limits).                    |
| Receiver count       | Any number, from configuration. Nothing in the tool is pairwise-only.                                      |
| Gain policy          | Every receiver on its own autogain: Airspy `auto`, RTLs readsb `auto` (`READSB_GAIN = "auto"`).            |
| Attenuation          | Per receiver, inline at the dongle, until its autogain sits off its floor. Recorded as receiver metadata.  |
| Port fairness        | Ports rotated between runs (cyclic Latin square). Cables stay with ports; attenuators stay with receivers. |
| Run length           | At least 48 h per port assignment, so every hour of the traffic cycle is in every assignment.             |
| Decoder confound     | Accepted. The comparison is of receiver chains (SDR plus decoder). The three RTLs share readsb.            |
| Source requirements  | Each source is one decoder's unreduced Beast output. Never an aggregator such as ultrafeeder's 30005.      |
| Tool home            | Separate repo, `fredsystems/beast-compare`, consumed here as a flake input that follows `nixpkgs-stable`.  |
| Language             | Python: pyModeS (decoding, CPR), polars (matching, binning), plotly (static HTML report), zstandard.       |
| Tool shape           | Two commands: `record` (long-running, on sdrhub) and `compare` (offline, any recorded window).             |
| Where it runs        | `record` as a systemd service on sdrhub. `compare` on a workstation (sdrhub has 15 GB RAM, mostly in use). |
| Storage              | `/opt/adsb/data/beast-compare/<run-id>/`. About 1-2 GB/day compressed for four receivers; 265 GB free.     |
| Results              | The HTML report and its parquet tables stay with the run data. No findings markdown in this repo.          |

## Method

### Recording

`record` reads a YAML config listing receivers, each with a name, a
Beast `host:port`, a stats source, and free-form metadata (SDR model,
attenuation, splitter port, host). Per receiver it:

- Keeps one TCP connection open, reconnecting with backoff, and logs
  every disconnect with its time span.
- Writes hourly zstd files of records `[u64 arrival_unix_ns][u8 len][frame]`,
  where `frame` is the unescaped Beast frame (type, 6-byte timestamp,
  signal, payload). Frames are kept raw so the analysis can change
  without re-recording. Unknown frame types are stored and ignored later.
- Polls the stats source once a minute into `stats.jsonl`: readsb's
  `/data/stats.json` over the tar1090 web port, or airspy_adsb's
  `stats.json` file.

The run directory also holds a manifest: the config as recorded, start
and stop times, and the tool revision. Changing anything mid-run (gain
mode, attenuator, port) means a new run, never an edit.

### Matching transmissions

1. **Decode** every frame: DF, address (from the ICAO field or the CRC
   parity overlay), type code.
2. **Align clocks.** Each receiver stamps frames with its own counter.
   For every receiver, fit offset and rate against the Airspy, piecewise
   per 60 s window, from messages that are effectively unique (DF17
   airborne position and velocity). Do not assume a 12 MHz rate; fit it.
   Detect discontinuities (decoder restarts, sample drops) and start a
   new segment at each one. Arrival time on the recorder only serves as
   a coarse window (a few seconds), so receivers on other hosts need
   nothing beyond normal NTP.
3. **Cluster.** Frames with identical bytes and aligned timestamps
   within tolerance (start at 20 us, tune from residuals) are one
   transmission. Clock alignment is what separates genuine repeats of
   identical content, such as DF11 squitters and DF17 identification.

### Attributing positions

Positions decoded by any receiver build one track per aircraft (CPR
global decode, local decode against the receiver position). Every
transmission within 30 s of a track point gets an interpolated position,
altitude, range, bearing and elevation angle. A receiver that only
caught a DF11 from an aircraft at 180 nm is credited at 180 nm.

### Metrics

Each metric is computed per receiver over its valid intervals only:

| Metric                          | Definition                                                                                   |
| ------------------------------- | -------------------------------------------------------------------------------------------- |
| Detection rate                  | Share of reference transmissions decoded, binned by range, elevation, bearing and altitude.  |
| Sensitivity curve               | Detection rate against each other receiver's signal level; the 50 % point and the top end.   |
| Exclusives                      | Transmissions, positions and aircraft visits heard only by this receiver, and missed only by it. |
| Acquisition                     | Per aircraft visit: first message and first position time, lead in seconds, range at the time. |
| Fade-out                        | Per visit: last message and last position, lag in seconds, range at the time.                |
| Continuity                      | Share of a visit's 10 s bins with at least one position; gap-length distribution.            |
| Message type                    | Detection rate by DF (17/18, 11, 4/5, 20/21, 0/16): long frames test the decoder harder.     |
| Traffic density                 | Detection rate binned by reference transmissions per second (overlapping replies).           |
| Timestamp quality               | Residual spread of aligned timestamps against the Airspy, per window: MLAT suitability.      |
| Health                          | Gain over time, noise floor, dropped samples or lost buffers, disconnects, clock segments.   |

A visit is an aircraft's continuous presence in the reference set, with
gaps under 5 minutes. With three or more receivers, acquisition and
fade-out are also reported as a pairwise matrix (who beat whom, how
often, by how much).

Uncertainty: every rate carries a bootstrap confidence interval that
resamples aircraft visits, not transmissions, because messages from one
aircraft are correlated. A difference inside the interval is reported as
no difference.

### Report

`compare` writes one self-contained HTML file per run window, plus the
parquet tables it was built from:

- A "where each receiver wins" table: best receiver and margin, with
  confidence interval, per range band, elevation band and density band.
- Polar detection maps (10 nm by 10 degree cells) per receiver, and
  difference maps against the Airspy.
- Overlaid polar range outlines, sensitivity curves, altitude-by-range
  coverage, and acquisition and fade-out lead histograms.
- A health timeline per receiver, with the invalid intervals shaded.

### Validity rules

An interval is excluded from a receiver's scores (not from the reference
set) when the receiver:

- is disconnected, or between clock segments;
- reports dropped samples or lost buffers;
- has its gain pinned at its lowest step (it is clipping, as the Pro
  Stick Plus was at 0 dB on 2026-11-07) or at its highest.

A receiver valid for under 90 % of a run is reported, but its results
are marked not comparable.

### Limits

- Transmissions that no receiver decoded are invisible, so detection
  rates are relative to the best receiver at each moment, not absolute.
- The splitter's port balance at 1090 MHz is unknown, since 1090 is near
  the top of its rated band. Rotation averages it out, and the pooled
  analysis estimates it as a per-port term.

## Execution model

Work runs in two repos. Tool subtasks (2.1, 2.2, 2.5-2.11) are in
`beast-compare`, and this repo's subtasks (2.3, 2.13) are wiring and
deployment. They can run concurrently where dependencies allow: 2.3
needs 2.2, the analysis chain is sequential, and 2.13 waits only on
hardware. Runs (2.4, 2.12, 2.14, 2.15) are user-assisted, because they
move hardware or need it left alone for days.

## Subtasks

### Recorder

- [ ] **2.1 Tool repo skeleton.** New `fredsystems/beast-compare`: a
      flake exporting the package and a dev shell, a `beast-compare`
      entry point with `record` and `compare` subcommands (stubs),
      pytest, ruff and mypy strict, the `fredsystems/precommit-base`
      hooks, and CI running all of them.
- [ ] **2.2 Beast parser and `record`.** Streaming parser (0x1a
      escaping, frame types 1-3, unknown types kept), the YAML config,
      per-receiver connections with reconnect and backoff, hourly zstd
      record files, `stats.jsonl` polling, and the run manifest. Tests:
      parser against escaped and truncated fixtures, file round trip,
      reconnect after a dropped connection.
- [ ] **2.3 Wire the recorder on sdrhub.** Add the `beast-compare`
      flake input (load `nixos-add-flake-input`). New
      `modules/services/beast-compare.nix` with options for the receiver
      list and data directory, and a systemd service on sdrhub. If the
      module is exported through `nixosModules`, document it in
      MODULES.md (`check-doc-drift.sh`). Publish the decoders' Beast
      ports on loopback only: `airspy_adsb` as `127.0.0.1:30105:30005`,
      `tar1090_rtlsdr` as `127.0.0.1:30106:30005`. Verify with
      `nixos-eval-impacted-hosts`, then deploy.
- [ ] **2.4 Recording dry run.** One hour, two receivers. Pass: each
      receiver's recorded frame count is within 1 % of the messages its
      decoder reported over the same hour.

### Analysis

- [ ] **2.5 Ingest and decode.** Recording files into a polars frame:
      receiver, arrival time, counter, signal, bytes, DF, address, type
      code. Tests on fixture recordings.
- [ ] **2.6 Clock alignment.** Piecewise offset and rate fit against the
      reference receiver, discontinuity detection, residual output.
      Tests on synthetic streams with known offset, drift and a reset.
- [ ] **2.7 Transmission clustering.** Tests with synthetic repeats of
      identical content, receivers missing frames, and a receiver with a
      clock reset.
- [ ] **2.8 Tracks and position attribution.** CPR decode, per-aircraft
      tracks, interpolation, range, bearing and elevation from the
      receiver position. Tests against hand-checked positions.
- [ ] **2.9 Validity masks.** From `stats.jsonl`, disconnect logs and
      clock segments, per the validity rules above.
- [ ] **2.10 Metrics.** Everything in the metrics table, with the
      visit-level bootstrap. Tests on synthetic clusters with known
      answers.
- [ ] **2.11 Report.** The HTML report and parquet output described
      above.
- [ ] **2.12 Two-receiver baseline.** Preconditions: the 10 dB
      attenuator is fitted to the Pro Stick Plus (add 10 dB more if its
      gain still settles at 0), and both autogains have been off their
      floors for 24 h. Record 48 h, swap the two receivers' ports, and
      record 48 h more. Run `compare` on each half and on the pair pooled.

### Four receivers

- [ ] **2.13 Onboard the v3 and v4.** Set serials with `rtl_eeprom`
      (`00001093` on the v3, `00001094` on the v4). Add `tar1090_rtlv3`
      on acarshub and `tar1090_rtlv4` on vdlmhub, modelled on
      `tar1090_rtlsdr`: the same image, `READSB_GAIN = "auto"`, the
      device by serial, the Beast port published on 30005 and opened in
      the firewall, and the web port published for stats. vdlmhub's
      4-port USB hub is full, so its dongle goes on a root port.
      Confirm the v4 is detected by the image's driver (the v4's R828D
      tuner needs the RTL-SDR Blog driver). Add both to the recorder
      config, then attenuate each until its gain is off the floor.
- [ ] **2.14 Four-receiver dry run.** Repeat 2.4 with all four sources,
      including the remote hosts.
- [ ] **2.15 Four-receiver run.** Four port assignments (cyclic Latin
      square, so every receiver uses every port once), 48 h each, about
      8 days. Report each assignment and the pooled result with the
      per-port term.

## Out of scope

- Choosing which receiver feeds ultrafeeder or MLAT. The results inform
  that decision; making it is a separate change.
- Antenna or site comparisons. The tool would run them unchanged, but
  this plan holds the antenna fixed.
- Sample rate (`AIRSPY_ADSB_SAMPLE_RATE`). The Airspy R2 supports 24
  MSPS. Comparing 20 against 24 is a later use of this method.
- Repointing the ADS-B Grafana dashboard's local-signal panels, which
  went blank when ultrafeeder became network-only.
