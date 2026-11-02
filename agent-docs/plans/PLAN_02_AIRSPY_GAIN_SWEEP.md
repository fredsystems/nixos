# Plan 02: Airspy gain sweep against a fixed RTL-SDR control

- **Status:** planned
- **Branch:** none yet

## Goal

Pick the Airspy's RF gain on sdrhub from a measurement that can actually
tell gains apart, then either pin that gain or keep airspy_adsb's
built-in `auto`. The Airspy shares one antenna with the 1090 RTL-SDR
through a wall-powered splitter, so the RTL (decoded by `tar1090_rtlsdr`)
is a true control: same aircraft, same signal, same moment.

## Why the first sweep does not decide this

The 2026-11-01 sweep (16, 18, 20, 21, auto; 15 minutes each) was enough
to replace the configured gain of 16 with `auto`: 16 was the only step
where the Airspy did no better than the RTL, 20 was the best fixed step,
21 added about 4 dB of noise for no gain in weak-signal SNR, and `auto`
settled at 20 within a minute. It was not enough to rank gains against
each other:

- **The control moved.** `tar1090_rtlsdr` was in autogain1090's two-hour
  initial period and moved between 36.4 and 40.2 dB during every step,
  so each Airspy/RTL ratio was against a different reference.
- **The aircraft metric was wrong.** A 15-minute union of hexes counts an
  aircraft for both receivers even when one acquired it minutes earlier.
  Acquisition time, range and per-aircraft message rate matter; set
  membership does not.
- **Ordered steps confound time with gain.** Traffic falls through the
  evening, and 16, 18, 20, 21 ran in that order with no repeated baseline
  to detect drift.

## Decisions

| Topic            | Decision                                                                                    |
| ---------------- | ------------------------------------------------------------------------------------------- |
| Container AGC    | No custom autogain in the airspy_adsb image. Its built-in `auto` is the benchmark to beat.  |
| Control          | RTL gain frozen for the run by touching autogain1090's `suspend` file; removed afterwards.  |
| Gain mechanism   | Live: write `/run/s6/container_environment/AIRSPY_ADSB_RF_GAIN`, restart the s6 service.    |
| Reverting        | Any container restart restores the configured gain. The run also restores it on exit.      |
| Runner           | `systemd-run --user` on sdrhub. logind has `KillUserProcesses=true`; the user lingers.      |
| Collection       | Raw 5 s snapshots on sdrhub; analysis on a workstation (sdrhub has no python).              |
| Step order       | Shuffled, with the baseline repeated last to detect drift.                                  |
| Windows          | 3 minutes settle (discarded), 20 minutes measured per step.                                 |
| Outcome          | Keep `auto` unless a fixed gain clearly beats it in the far range bands.                    |

## Preconditions

- The RTL's autogain has finished its initial period and has held one
  gain for several hours: `autogain_initialized` exists under
  `/opt/adsb/data/tar1090_rtlsdr/globe_history/autogain/`, and
  `docker logs tar1090_rtlsdr | grep "tuner gain set"` shows no recent
  change.
- `AIRSPY_ADSB_RF_GAIN=auto` is deployed; it is the baseline. Check the
  gain it reports in `stats.json` has held steady before starting.
- Run during a busy traffic period and outside nearby thunderstorm
  activity, so the far bands have enough samples.

## Method

**Steps.** `auto`, `21`, `18`, `20`, `19`, `auto`: the fixed values
bracket where `auto` settled (20). About 2 h 20 min in total.

**Collector.** Every 5 seconds, for both `tar1090_airspy` and
`tar1090_rtlsdr`, append one line per aircraft from `aircraft.json`:
timestamp, receiver, `hex`, `r_dst`, cumulative `messages`, `seen`,
`seen_pos`, `rssi`. Tag every line with the Airspy gain in effect and a
settle/measure flag. Also append airspy_adsb's `stats.json` once a
minute. Before the first step, check `docker`, `jq` and `comm` are on
PATH and do a one-minute dry run that touches nothing.

**Metrics per step**, measured windows only:

- **Sensitivity by range.** For aircraft both receivers hold, the
  Airspy/RTL ratio of message-count deltas over the same intervals,
  binned by `r_dst` (0-50, 50-100, 100-150, 150-200, 200+ nm). Far bands
  show sensitivity; near bands show overload.
- **Acquisition.** For aircraft neither receiver held at the window
  start: each receiver's first position time (sample time minus
  `seen_pos`), which got it first, the lead in seconds, and `r_dst` at
  acquisition.
- **Fade-out.** Last position time and range for departing aircraft;
  which receiver held on longer.
- **Airspy internals.** Median noise and SNR, strongest RSSI and lost
  buffers from `stats.json`, plus the gain it reports under `auto`.

**Validity.** If the two baseline windows disagree by more than a few
percent in the 100+ nm bands, conditions drifted and the run is not
used.

## Subtasks

- [ ] 2.1 Collector script, with the preflight tool check and gain/phase
      tagging.
- [ ] 2.2 Analysis script producing the per-step metrics above.
- [ ] 2.3 Dry run: one minute at `auto`, no gain change, analysis end
      to end.
- [ ] 2.4 Full run with the RTL autogain suspended; resume it afterwards.
- [ ] 2.5 Decide `auto` versus a fixed gain from the far-band and
      acquisition results.
- [ ] 2.6 Commit the chosen `AIRSPY_ADSB_RF_GAIN` to
      `docker/sdrhub/airspy_adsb.env` and deploy sdrhub.

## Out of scope

- An autogain in the airspy_adsb container.
- Sample rate (`AIRSPY_ADSB_SAMPLE_RATE`). The device is an Airspy R2
  (firmware "AirSpy NOS", native 10 / 2.5 MSPS), so the current 20 MSPS
  is supported and 24 is available; a separate run, only worth doing
  once the gain is settled.
- Repointing the ADS-B Grafana dashboard's local-signal panels, which
  went blank when ultrafeeder became network-only.
