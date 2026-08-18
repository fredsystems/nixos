# Backup and NAS-monitoring design

Working design document for the two items **excluded by explicit decision**
from `AUDIT-2026-08-04.md` (see its "Scope exclusions, by explicit decision"),
plus the NAS/UniFi monitoring question that surfaced alongside them.

Status: **partially implemented.** Sequencing item 1 (source-side backup
verification) has landed on branch `backup-verification`; everything else is
still design. Open questions are collected in the last section and several of
them block the remaining work.

| Item                                   | State                                                                   |
| -------------------------------------- | ----------------------------------------------------------------------- |
| 1. Source-side verification            | LANDED. Freshness/size/retention metrics plus 8 alert rules. See Part 9 |
| 2. ADSB SQLite dump handling           | Design only. Blocked on the endurance decision in Part 8                |
| 3. Discord newest-only + NAS retention | Design only. Must land with the `--delete` removal                      |
| 4. rsync flag normalisation            | Design only. Blocked on measuring the NAS                               |
| 5. Restore test                        | Being handled separately by fred                                        |
| 6-9                                    | Design only                                                             |

Note that item 1 as landed covers the **source side only**. The NAS-side half
-- proving the pull happened -- is still open and is the larger remaining gap.
See Part 9 for exactly where the boundary sits.

Scope of this document:

1. The three existing NAS-side rsync jobs, and what is wrong with them.
2. Prometheus TSDB snapshots: are they restorable, and is the pull correct.
3. Discord DB backup: move retention from the VPS to the NAS.
4. ADSB backup: add SQLite dump handling for acarshub and acarshubv4.
5. What high-value data is still not backed up at all.
6. NAS and UniFi monitoring (deferred until the backup work is settled).

Explicitly **out of scope**: disko / nixos-anywhere for fredvps. That is the
other deferred audit item and is a separate design conversation.

---

## Part 0 -- Facts this design rests on

Verified against the checkout at `bb713acb` and against the flake's own
nixpkgs pin. Where something could not be verified from the checkout, it is
listed as an open question rather than assumed.

### The clock offset is real and it is one hour

Every host in the fleet is `America/Denver`
(`features/common/locale/default.nix`, confirmed by `nix eval` on both sdrhub
and fredvps). The NAS is **not DST-corrected**, so it sits on MST (UTC-7)
year-round while the fleet is currently on MDT (UTC-6).

Therefore, during DST:

```text
NAS-scheduled time + 1 hour = actual wall-clock (MDT) time
```

All NAS times below are given in both forms. This matters because every
"does the pull happen after the dump" question depends on it, and the answer
changes twice a year.

### The three NAS jobs, normalised to wall clock

| NAS job      | NAS time | Wall clock (MDT) | Source                                                 |
| ------------ | -------- | ---------------- | ------------------------------------------------------ |
| ADSB pull    | 0000     | 01:00            | `sdrhub:/opt/adsb` -> `/volume1/docker`                |
| Prom pull    | 0300     | 04:00            | `sdrhub:/var/lib/prometheus2/data/snapshots`           |
| Discord pull | 2100     | 22:00            | `fredvps:/mnt/discord-storage/` -> `/volume1/discord/` |

### The fleet-side jobs they depend on

| Fleet job                  | Schedule                              | Declared at                                        |
| -------------------------- | ------------------------------------- | -------------------------------------------------- |
| `createPrometheusSnapshot` | `daily` (00:00), no jitter            | `modules/monitoring/master/prometheus.nix:145-152` |
| `prunePrometheusSnapshots` | `daily` (00:00), no jitter, 30d       | `modules/monitoring/master/prometheus.nix:136-143` |
| `discord-db-backup`        | 01:00 + `RandomizedDelaySec=15m`, 14d | `hosts/linux/fredvps/discord-backup.nix:121-136`   |

### Where the ADSB SQLite databases actually are

The audit's subagent flagged this as an unresolved discrepancy. It is now
resolved:

- `hosts/linux/sdrhub/configuration.nix` mounts
  `/opt/adsb/data/acarshub:/run/acars` for the `acarshub` container and
  `/opt/adsb/data/acarshubv4:/run/acars` for `acarshubv4`.
- ACARSHub writes its database to `/run/acars/messages.db` inside the
  container.
- So the host paths are `/opt/adsb/data/acarshub/messages.db` and
  `/opt/adsb/data/acarshubv4/messages.db`, exactly matching
  `scripts/acarshub-db-repair.sh:27-30`.
- The `/database:exec,size=64M` tmpfs in the same container block is **not**
  where the DB lives and is a red herring.

Both databases are WAL-mode. `scripts/acarshub-db-repair.sh:276` stops both
containers and sleeps specifically to let SQLite release WAL locks. This is
the same property that made the old `cp` in `discord-backup.nix` wrong.

Size evidence from the repo: a stale `messages.db.back` was found occupying
**5.6 GB** (`acarshub-db-repair.sh:280-284`), the VACUUM path needs roughly
**10 GB** of scratch (`:16`), and the FTS5 shadow tables alone are about
**4 GB** (`:75`).

---

## Part 1 -- Prometheus: the snapshots are the right artifact

**Question asked:** are those snapshots exactly what is needed for recovery,
and is the timing sound?

**Answer: yes on the artifact, yes on the timing, but the pull itself is
probably very inefficient and the restore has never been tested.**

### Ingesting a snapshot

A Prometheus admin-API snapshot is not a dump format needing conversion. It
is a complete, self-consistent TSDB directory: block directories, each with
`chunks/`, `index`, and `meta.json`. There are two restore paths:

1. **Inspect without disturbing production.** Run a throwaway Prometheus with
   `--storage.tsdb.path` pointed straight at the restored snapshot directory.
   Nothing needs to be merged first. This is also how a restore test should be
   done.
2. **Restore in place.** Stop Prometheus, copy the snapshot's block
   directories into the data directory, start it again.

So the answer to "I have no idea how to ingest that data" is: point a
Prometheus at it. No conversion step exists or is needed.

Two caveats that matter:

- The API includes the in-memory head block by default (`skip_head` defaults
  to false), so a snapshot is current as of the moment it was taken rather
  than only as of the last complete block. Good.
- **This has never been tested.** `AUDIT-2026-08-04.md` Part 7 item 4 makes
  the general point: a backup without a tested restore is not a backup. A
  restore test belongs in the same change as any of this work.

### Timing is fine

Snapshot at 00:00 MDT, pull at 04:00 MDT. Four hours of slack. Correct
ordering, comfortable margin.

### Two real defects, neither of them timing

**Defect 1: the snapshot and prune timers both fire at 00:00 with no
jitter.** `createPrometheusSnapshot` and `prunePrometheusSnapshots` are both
`OnCalendar = "daily"` with no `RandomizedDelaySec`. They race every night.
The prune only deletes directories older than 30 days so the practical risk
is low, but the fleet has a `RandomizedDelaySec` convention (see
`discord-backup.nix:134` and the audit's item 3.4) and these two are
inconsistent with it.

**Defect 2, and this is the likely cause of "these jobs are super slow":
`rsync -av` without `-H` on a hardlinked tree.**

Prometheus builds each snapshot out of **hardlinks** to the existing block
files. On sdrhub, 30 days of snapshots are therefore nearly free. But:

- `rsync -av` does not preserve hardlinks. `-H` does.
- Without `-H`, every hardlink is transferred and stored as an independent
  full copy. Thirty snapshots of a 90-day TSDB become thirty full copies on
  the NAS instead of one plus deltas.
- Worse, each snapshot directory has a **new timestamped name**, so rsync
  cannot match last night's files against tonight's by path, and there is no
  `--fuzzy` to help it. Every block is retransmitted from scratch every
  night.

That is a plausible explanation for both the runtime and the space
consumption. Candidate fixes, in order of preference, all needing measurement
on the real hardware first:

| Option                                   | Effect                                                      | Risk on an old NAS                                          |
| ---------------------------------------- | ----------------------------------------------------------- | ----------------------------------------------------------- |
| Add `-H`                                 | Collapses duplicate content to hardlinks at the destination | Builds an in-memory hardlink map; memory cost on a 2 GB box |
| Add `--fuzzy`                            | Lets rsync find a delta basis in a renamed directory        | Low; already in use on the discord job                      |
| `--link-dest` against the previous night | Classic rotating-snapshot pattern, near-zero duplication    | Needs a stable "previous" path, so a wrapper script         |
| Pull fewer snapshots                     | Do not mirror all 30 days                                   | Reduces recovery granularity                                |

`-H` and `--link-dest` both long predate any rsync the NAS could be running,
so the "no new rsync" constraint does not rule them out. Confirming the
actual rsync version is an open question below.

---

## Part 2 -- Discord: newest-only on the VPS

**Goal:** stop holding 14 copies of a roughly 1 GB database on the VPS, and
move retention to the NAS.

Current state (`hosts/linux/fredvps/discord-backup.nix:105-118`): the job
writes `discord_db-<date>.sqlite` via SQLite's online `.backup` API into a
`.part` file, atomically renames it, then culls with
`find ... -mtime +14 -delete`. So the VPS holds up to 14 copies at roughly
1 GB each (`:102`), and the NAS mirrors all of them.

### The change is two lines on the VPS and one flag on the NAS

On the VPS, change the retention sweep from "older than 14 days" to "all but
the newest". On the NAS, take over the 14-day culling.

**The critical detail, and it is easy to get wrong: `--delete` must come off
the NAS discord job at the same time.**

`rsync --delete` removes files at the destination that no longer exist at the
source. If the VPS keeps only the newest copy while the NAS job still passes
`--delete`, then the very first pull after the change deletes the other
thirteen copies from the NAS. The result would be a single backup on each
side, which is strictly worse than today and would look like it worked.

So the two halves of this change are **not independent** and must land
together:

| Side | Before                   | After                                   |
| ---- | ------------------------ | --------------------------------------- |
| VPS  | keep 14 days             | keep newest only                        |
| NAS  | `--delete`, no retention | no `--delete`, `find -mtime +N -delete` |

Consequences to accept deliberately:

- Dropping `--delete` means the NAS no longer tracks source deletions at all
  for this path, so NAS-side retention becomes the **only** thing bounding
  growth. If that cull breaks, the volume fills silently. This is a direct
  argument for the volume-capacity alerting in Part 5.
- `--fuzzy` becomes more valuable, not less: with one file per night under a
  new name each time, fuzzy matching against the previous night's file is the
  only thing that makes the transfer a delta rather than a full 1 GB copy.
- The comment at `discord-backup.nix:101-104` explains that `VACUUM INTO` was
  deliberately rejected in favour of `.backup` precisely to preserve rsync's
  ability to delta successive backups. That reasoning holds and gets more
  important here.

### Timing

Backup at 01:00-01:15 MDT. Pull at 22:00 MDT the same day. So the pull is
about 21 hours behind the newest backup, and just before the next pull the
NAS copy is about 45 hours old.

The recollection that "discord backups lag a day" is therefore approximately
right. It is not a defect -- ordering is correct and there is no race -- but
if a fresher copy is wanted, the pull should move to roughly 02:00-03:00 MDT
(0100-0200 NAS time), which would also spread NAS load away from the other
jobs.

---

## Part 3 -- ADSB: real dump handling for acarshub and acarshubv4

**Goal:** stop rsyncing live WAL-mode SQLite files, and treat the two message
databases the way discord is now treated.

### Why the current job is unsafe, precisely

`rsync -av --delete --exclude='.htaccess' sdrhub:/opt/adsb /volume1/docker`
copies `/opt/adsb/data/acarshub/messages.db` and
`/opt/adsb/data/acarshubv4/messages.db` while both containers are running and
writing.

This is the **same defect** the audit already fixed in `discord-backup.nix`,
for the same reasons documented at `discord-backup.nix:69-88`:

- rsync copies the main DB file but not necessarily a consistent view of the
  `-wal` and `-shm` siblings, so anything committed since the last checkpoint
  can be missing.
- rsync is not atomic against a live writer. A checkpoint landing mid-copy
  yields a torn file, which surfaces as "database disk image is malformed" at
  restore time, which is the one moment it matters.

The rest of `/opt/adsb` is genuinely fine to copy as-is. Per the inventory,
it is decoder caches, graphs1090 RRDs, globe history, feeder identity dirs
and config -- all either regenerable or safe to copy incoherently.

### Proposed shape

A new nightly `acarshub-db-backup` service on **sdrhub**, modelled directly
on `discord-backup.nix`, which is the reference implementation the fleet
already reviewed and hardened:

1. `sqlite3 <db> ".backup '<dest>.part'"` for each of the two databases.
2. Atomic `mv` into place, so a name that looks like a backup only exists
   once it is one.
3. Clear stale `.part` files at the start rather than trusting the retention
   sweep.
4. Keep **newest only** on sdrhub, matching the new discord policy.
5. `RandomizedDelaySec`, plus the same conservative hardening set, with the
   same deliberate omission of `ProtectSystem`/`ProtectHome`.

**Where to write the dumps.** Writing them under `/opt/adsb` means the
existing 0000 NAS job picks them up with no NAS-side change. That argues for
something like `/opt/adsb/backups/`. But see the `--delete` interaction
below, which is the same trap as Part 2.

**Do not follow the repair script's approach.** `acarshub-db-repair.sh` stops
both containers to release WAL locks. A backup must not do that: `.backup`
exists so that concurrency is the API's problem, and taking the decoders down
nightly would lose messages.

### Three problems that need decisions

**Problem 1: NVMe write endurance.** `alert-rules/smart-alerts.yaml:9-17`
records sdrhub at **54% of rated write endurance with 37.8 TB written** --
by far the worst drive in the fleet. Adding a nightly full copy of two
multi-gigabyte databases could add on the order of 10 GB of writes per day to
exactly the drive that is already the fleet's leading replacement candidate.

This is a genuine tradeoff, not a detail. Options: accept it, dump less
often than nightly, dump straight to the NAS over the network instead of
landing locally first, or replace the drive as part of this work.

**Problem 2: `--delete` again.** If the dumps are newest-only on sdrhub and
retention moves to the NAS, then the ADSB job cannot keep `--delete` for the
backups path. But the rest of `/opt/adsb` arguably still wants `--delete` so
the mirror tracks removals. That points at **splitting the ADSB pull into two
jobs**: one for `/opt/adsb` with `--delete`, one for the dumps without it.

**Problem 3: timing.** The dump must finish before the pull at 01:00 MDT. A
multi-gigabyte `.backup` on a busy host is not instant, and the repair script
budgets 30-90 minutes for its (heavier) VACUUM path. There is also a possible
overlap between a slow 01:00 MDT ADSB pull and the 04:00 MDT Prometheus pull,
both against sdrhub, on a NAS that is already slow. Needs measurement.

### On `--exclude='.htaccess'`

No `.htaccess` is tracked anywhere in this repo, and no rsync command exists
in it either -- both confirmed by search. So the exclude protects a file that
exists **only on the NAS**, preventing `--delete` from removing it. Harmless,
worth keeping, and worth a comment recording why, because its purpose is
otherwise unguessable.

---

## Part 4 -- rsync flags: normalise across all three jobs

The three jobs use three different flag sets. The discord job is the most
evolved; the other two never got the same treatment.

| Flag        | ADSB | Prom | Discord     | Assessment                                                                                                                                            |
| ----------- | ---- | ---- | ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| `-a`        | yes  | yes  | no (`-rlt`) | Discord's explicit `-rltv --no-perms --no-owner --no-group` is arguably more correct for a Linux-to-DSM copy, where preserving uid/gid is meaningless |
| `-H`        | no   | no   | no          | **Missing where it matters most** (Prometheus hardlinks). Irrelevant for the other two                                                                |
| `--fuzzy`   | no   | no   | yes         | Should be added to both others; it is what makes dated-filename backups deltas instead of full copies                                                 |
| `--delete`  | yes  | yes  | yes         | Must be **removed** from discord, and from any dumps path, per Parts 2 and 3                                                                          |
| `--partial` | no   | no   | no          | Worth considering on a slow link so an interrupted multi-GB transfer resumes                                                                          |
| `-z`        | no   | no   | no          | Probably leave off. LAN-speed compression on an Atom-class CPU is usually a net loss, and SQLite/TSDB blocks are not very compressible                |

Two cautions on the "these jobs are super slow" complaint:

- `--fuzzy` and `-H` are the two flags that plausibly matter here.
  Compression and `--partial` are unlikely to change throughput much.
- The RS818+ is an **Atom C2538 with 2 GB of non-ECC RAM**. `-H` on a large
  tree costs memory. Measure before committing.

---

## Part 5 -- What else should be backed up

From the fleet-wide inventory. Ordered by consequence of loss, not by effort.

| Rank | Data                                          | Where                            | Backed up now             | Consequence of loss                                                                                                                                                       |
| ---- | --------------------------------------------- | -------------------------------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1    | sops age keys (`~/.config/sops/age/keys.txt`) | every host                       | **No**                    | Host permanently cannot decrypt `secrets.yaml`. Must be re-provisioned as a new recipient. Not recoverable, only replaceable                                              |
| 2    | `fred-gpg`, `id_ed25519`, `id_rsa`            | inside sops `secrets.yaml`       | Only as ciphertext in git | Recoverable only while the age-key chain survives. If the original GPG material was never held outside sops, it is a real cryptographic identity with no independent copy |
| 3    | Frigate recordings **and** `frigate.db`       | nvrhub, one 4 TB XFS disk        | **No**                    | 7.9-year-old spinning disk, no redundancy. Loses video and event metadata in a single failure. About 2.05 TB                                                              |
| 4    | Browser profiles                              | Daytona, maranello               | **No**                    | Bookmarks, saved logins, extensions, history. Entirely outside Nix                                                                                                        |
| 5    | acarshub / acarshubv4 `messages.db`           | sdrhub                           | Copied, but unsafely      | Addressed by Part 3                                                                                                                                                       |
| 6    | `open-webui` chat history                     | fredhub                          | **No**                    | Non-regenerable if any history is valued. Distinct from the Ollama model cache next to it, which is a re-downloadable cache                                               |
| 7    | SyncClipboard history                         | sdrhub `/opt/adsb/syncclipboard` | Inside the ADSB pull      | Sensitive (0700 for a reason); currently mirrored by accident rather than by design                                                                                       |
| 8    | Grafana `grafana.db`                          | sdrhub                           | **No**                    | Mostly regenerable: all 8 dashboards and both datasources are Nix-provisioned. Any UI-created alert rule or dashboard is not. Unverified against the live instance        |
| 9    | DSM configuration itself                      | the NAS                          | **No**                    | The backup target's own config. Losing it means rebuilding the thing all restores depend on                                                                               |

Two structural gaps that outrank most of the table:

**There is no offsite copy of anything.** Every path in this document ends at
one NAS in one building. That is not 3-2-1; it is 2-1-0. Fire, theft, flood,
ransomware, or a controller failure that takes both RAID members loses the
fleet's only copy. The NAS itself is a 2018 unit with non-ECC RAM.

**Nothing verifies that any of these jobs ran.** This is the single highest
value gap in this document and it is cheap to close. There is no metric, no
alert, and no deadman for any of the three rsync jobs. A cron that silently
stops, a full volume, or a broken SSH key produces exactly the same
observable state as a healthy night: nothing.

Note this is **not** something SNMP can fix. There is no OID for "did the
0300 rsync succeed". Two candidate mechanisms, both of which reuse machinery
the repo already has:

1. **Deadman pings.** `healthchecks.io/endpoint` is already a sops secret and
   already wired into a deadman at
   `modules/monitoring/master/prometheus.nix:46-60`. Appending a `curl` to
   each NAS cron job gives per-job coverage with no new infrastructure.
2. **A freshness metric.** Have the NAS, or a fleet host, write the age and
   size of the newest backup to the node_exporter textfile directory
   (`/var/lib/node_exporter/textfiles`, already in use), then alert on age.
   This is strictly better than a deadman because it catches "the job ran and
   produced a zero-byte file", which a ping cannot.

Doing both is defensible: (1) catches "did not run", (2) catches "ran and
produced garbage".

**And a restore test.** Per the audit's Part 7 item 4, a backup without a
tested restore is not a backup. `acarshub-db-repair.sh:280-284` deleting a
stale 5.6 GB backup with no replacement is a preview of that failure mode.
At minimum: `PRAGMA integrity_check` on the newest SQLite dumps, and a
periodic throwaway-Prometheus load of the newest TSDB snapshot.

---

## Part 6 -- NAS and UniFi monitoring

Deferred until the backup work above is settled, but recorded now because the
research is done. The short version: **the NAS is worth monitoring over SNMP,
and the UniFi gear is not.**

### Synology RS818+ over SNMPv3

Hardware, verified against Synology's published spec: Atom C2538, 4 bays (8
with an RX418), **2 GB DDR3 non-ECC**, DSM 7.2.1-69057 Update 12. A 2018
model at the end of its DSM line, acting as the fleet's only backup target,
with non-ECC memory.

What is available in the pin:

- `prometheus-snmp-exporter` **0.30.1**.
- Upstream ships a prebuilt **`synology`** module in its `snmp.yml` covering
  `1.3.6.1.4.1.6574.{1,2,3,4,5,6,101,102,104}`. No generator run, no MIB
  compilation.
- The NixOS module has `configuration` (attrs), `environmentFile` with
  envsubst, and `enableConfigCheck` defaulting to true, which runs
  `snmp_exporter --dry-run` **at build time**. A malformed config fails the
  build rather than a 3am scrape.
- Port 9116 is unused anywhere in this repo.

Three findings that shape the implementation:

1. **The `synology` module has no CPU, RAM, or load metrics.** The only `cpu`
   match in its 1,476 lines is `cpuFanStatus`. Host-level health needs
   additional modules. snmp_exporter 0.30.1 supports multi-module scrapes
   (`?module=synology,if_mib`).

   | Module         | Provides                                           |
   | -------------- | -------------------------------------------------- |
   | `synology`     | RAID, disks, temps, fans, power, UPS, volume sizes |
   | `ucd_memory`   | `memTotalReal`, `memAvailReal`, swap               |
   | `ucd_la_table` | load average (`laLoadInt`)                         |
   | `if_mib`       | per-interface traffic and errors                   |

2. **The packaged `snmp.yml` has no v3 auth block.** It ships only
   `public_v1` and `public_v2`, both `noAuthNoPriv`. So pointing directly at
   `${pkgs.prometheus-snmp-exporter.src}/snmp.yml` cannot do v3. The fix is a
   `runCommand` that merges our own `auths:` stanza over the upstream modules
   and drops the unused ones, which also trims 61k lines to a few thousand --
   worth doing anyway for a slow target. Per upstream's README,
   `--config.expand-environment-variables` supports exactly `username`,
   `password`, and `priv_password` in `auths`, so credentials come from sops
   via `environmentFile` and never enter the store.

3. **DSM's v3 crypto is fixed at SHA + AES-128**, so `auth_protocol: SHA`,
   `priv_protocol: AES`, `security_level: authPriv`.

Exposure: loopback-only on `127.0.0.1:9116`, no `openFirewall`, following
`blackbox.nix:1-19`. The reasoning is identical and important --
`/snmp?target=<anything>` is an unauthenticated SNMP relay onto the LAN if
exposed.

**What already exists as of `bb713acb`.** A blackbox probe of
`https://nas.int.fredsystems.org/` landed in `blackbox.nix` alongside a DSM
vhost on sdrhub. Its comment makes the right argument -- the NAS is the only
upstream behind that nginx not managed by this flake, so a DSM update moving a
port produces no commit to review and no `up` metric to drop.

That is genuine coverage and it changes the priority of one rule below: a
reachability probe now exists, so `up{job="snmp"} == 0` becomes a
lower-priority duplicate of an existing signal rather than a new one. It does
**not** overlap with anything else here -- an HTTP 200 from the DSM login page
says nothing about RAID state, disk health, or volume capacity, which are the
reasons to add SNMP at all.

Alerts worth writing, all against metrics confirmed present in the module:

| Priority | Metric                                                           | Catches                                                                                                                                                       |
| -------- | ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1        | `synology_raidStatus`                                            | Degraded array. Highest-value rule here                                                                                                                       |
| 2        | `diskStatus`, `diskHealthStatus`, `diskBadSector`, `diskRetry`   | Per-disk failure                                                                                                                                              |
| 3        | `raidFreeSize` / `raidTotalSize`                                 | Volume capacity. Directly load-bearing: a full volume silently fails all three rsync jobs, and Parts 2 and 3 make NAS-side retention the only bound on growth |
| 4        | `up{job="snmp"} == 0`                                            | SNMP scrape failing. Lower priority since `bb713acb` -- the blackbox probe already covers plain reachability, so this mainly catches SNMP itself breaking     |
| 5        | `systemStatus`, `powerStatus`, `systemFanStatus`, `cpuFanStatus` | Chassis health                                                                                                                                                |
| 6        | `temperature`, `diskTemperature`                                 | Thermal                                                                                                                                                       |
| 7        | `upsInfoStatus`, `upsInfoLoadValue`                              | Only if a UPS is actually attached                                                                                                                            |

**The trap this repo has already hit once.** `smart-alerts.yaml:19-44`
documents how seven NVMe-only rules silently did not apply to nvrhub's
spinning disk. `synology_diskRemainLife` has the identical shape: it is
SSD-oriented and tends to return junk or `-1` for HDDs. Thresholds must be
read off the actual drives first, the way the SMART baseline table was.

Rules also need a `tests/synology-alerts-test.yaml`, since
`promtool check rules` and `promtool test rules` are enforced in both a
pre-commit hook and a flake check (`flake/dev/checks.nix:25-55`).

### UniFi: do not use SNMP

Research findings, all against current sources:

- **The UniFi MIBs have not been updated in roughly five years.** The
  `ubiquiti_unifi` module walks exactly one subtree,
  `1.3.6.1.4.1.41112.1.6`, and it is entirely radio/VAP/interface counters.
  Nothing about controller health, client counts, gateway WAN state, or PoE.
- Enabling it is now buried under **Settings > CyberSecure > Traffic
  Logging**, which is greyed-out-but-clickable for self-hosted setups.
- There is an **open, Ubiquiti-confirmed provisioning bug** (support request
  #5046092) where the controller fails to push the `snmp.*` block to APs, so
  `snmpd` never starts and the UI checkbox lies.
- **Ultra and Flex models do not support it at all**, and SNMP traps are not
  available.
- It is per-device polling: every AP and switch is its own target with its own
  credentials.

Upstream's own alert rules confirm how little is there: two VAP error-rate
ratios (`snmp_ubiquiti_wifi.yml`) plus a single `up != 1`
(`snmp_general.yml`). There is no Synology mixin at all.

**The right tool is `unpoller`**, which talks to the controller API. In the
pin at **2.39.0**, `broken = false`, with a NixOS module
(`services.unpoller`). Its `unifi.*.pass` is `types.path` with
`apply = v: "file://${v}"`, so it is genuinely sops-compatible and the
password never enters the store. Native Prometheus output on `:9130`.

Two problems to resolve before committing to it:

1. **Version gap.** Upstream is v3.3.1 (June 2026); the pin has 2.39.0.
   Merged fixes not in the pin include DPI on UniFi Network 9.1+ firmware and
   Site Manager remote-API support.
2. **The NixOS module has no `api_key` option and no freeform or `settings`
   escape hatch** -- the option set is closed, confirmed by reading the
   module. UniFi now supports API-key auth, which is _mutually exclusive_
   with user/pass. If the controller is on a modern UniFi OS where a local
   read-only admin is awkward, the packaged module cannot express the needed
   config. That means a `services.unpoller` override, a package bump, or an
   upstream nixpkgs PR.

Neither is a blocker; both are the difference between a two-hour job and a
weekend.

Keep the NAS and UniFi as **separate modules and separate rule files**. They
share nothing but a transport, and on this evidence UniFi should not use that
transport at all.

---

## Part 7 -- Suggested sequencing

Ordered by consequence of the gap staying open, following the audit's Part 9
convention.

| Order | Work                                                    | Rationale                                                                                                                                |
| ----- | ------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| 1     | Backup-job verification (deadman plus freshness metric) | Cheapest item here and the only one that makes existing backups trustworthy. Everything else is worth less while nothing reports failure |
| 2     | ADSB SQLite dump handling                               | Closes an active correctness defect: live WAL-mode DBs are being copied unsafely today                                                   |
| 3     | Discord newest-only plus NAS retention                  | Reclaims VPS disk. Must land as one change with the `--delete` removal                                                                   |
| 4     | rsync flag normalisation (`-H`, `--fuzzy`)              | Probably the answer to "these jobs are super slow". Measure first                                                                        |
| 5     | Restore test                                            | Converts all of the above from hope into evidence                                                                                        |
| 6     | sops age-key and GPG escrow                             | Highest-consequence item in Part 5, but needs its own security conversation                                                              |
| 7     | Offsite copy                                            | The 2-1-0 problem. Largest structural gap, largest cost                                                                                  |
| 8     | Synology SNMPv3 plus alerts                             | High value, few unknowns once the walk output exists                                                                                     |
| 9     | UniFi via unpoller                                      | Real value, blocked on the auth and version questions                                                                                    |

Frigate's 2 TB is deliberately not in this list. It needs a decision about
whether surveillance footage is worth offsite capacity at all, which is a
policy question rather than an implementation one.

---

## Part 8 -- Open questions

These block implementation. Grouped by what they block.

### Blocking the NAS-side rsync changes

1. **What rsync version is on the NAS?** `rsync --version`. Decides whether
   `-H`, `--fuzzy`, `--partial`, and `--link-dest` are all available. All are
   old features, so this is expected to be fine, but the "no new rsync"
   constraint makes it worth confirming rather than assuming.
2. **How long does each job currently take, and what is the actual data
   volume?** Without a baseline there is no way to tell whether a flag change
   helped. Even rough wall-clock figures from the DSM task scheduler would
   do.
3. **How is NAS-side retention best expressed?** `find -mtime` in the same
   cron line, a separate scheduled task, or DSM's own snapshot/retention
   features. This depends on how the three jobs are currently scheduled --
   Task Scheduler entries, or crontab.
4. **Is the NAS volume RAID-protected, and how full is it?** Determines both
   how much retention is affordable and how bad the single-copy problem is.

### Blocking the ADSB dump work

1. **Current on-disk size of both `messages.db` files, and sdrhub's free
   space.** The repo mentions 5.6 GB and 4 GB figures but those are historical.
   Two nightly full copies need room, and Problem 1 in Part 3 (54% NVMe
   endurance consumed) needs real numbers to weigh.
2. **Is a nightly full dump of both databases acceptable given that
   endurance figure?** If not, the options are a lower frequency, dumping
   straight to the NAS without landing locally, or replacing the drive as
   part of this work. This is a judgement call, not a technical unknown.
3. **Does fredvps's `/opt/adsb/acarshub` hold a third `messages.db`?** The
   repo shows the same `/run/acars` mount shape there, but
   `acarshub-db-repair.sh` only knows about the two sdrhub paths, and nothing
   in the checkout settles it.
4. **Split the ADSB pull into two jobs, or keep one?** Per Problem 2, the
   dumps path cannot carry `--delete` while the rest of `/opt/adsb` probably
   should.

### Blocking the discord change

1. **Move the pull earlier?** It currently runs 21 hours behind the backup.
   Moving it to roughly 0100-0200 NAS time (02:00-03:00 MDT) would make the
   NAS copy much fresher and spread NAS load. Any reason not to?
2. **How many copies should the NAS keep?** 14 preserves current behaviour.
   More is now cheap, since the VPS is no longer the constraint.

### Blocking the verification work

1. **Can the NAS reach healthchecks.io outbound?** Decides whether per-job
   deadman pings are possible at all, or whether verification has to be
   inferred fleet-side from file mtimes.
2. **Deadman, freshness metric, or both?** Recommendation is both, for the
   reasons in Part 5.

### Blocking the Synology SNMP work

1. **An actual `snmpwalk` against the box**, once SNMPv3 is enabled, from
   sdrhub:

   ```bash
   snmpwalk -v3 -l authPriv -a SHA -x AES -u <user> \
     -A <authpass> -X <privpass> 192.168.31.16 1.3.6.1.4.1.6574
   ```

   Specifically needed: whether `upsInfoStatus` is populated (decides whether
   the UPS rules are real coverage or permanently-empty rules, which is
   exactly what `scripts/check-alert-metrics.sh` exists to catch); what
   `diskRemainLife` returns for spinning disks; and **how long the walk
   takes**, since a slow walk shows up as a flapping `up` metric rather than
   a slow graph. Redact the serial number.

2. **Is a UPS actually attached?** Recollection is "maybe". The walk answers
   this definitively.
3. **Is the RX418 expansion unit present?** Changes the expected
   `diskIndex` range and therefore the per-disk rules.

### Blocking the UniFi work

1. **What runs the controller** -- UDM/UDM-Pro, CloudKey, self-hosted, or
   Cloud Gateway?
2. **What UniFi Network version?** Decides whether the DPI and Site Manager
   fixes missing from the 2.39.0 pin actually matter.
3. **What devices** -- APs, switches, gateway? Any Flex or Ultra models?
4. **Can a local read-only admin be created, or is it API-key only?** This is
   the one that decides whether the packaged NixOS module is usable at all.

### Cross-cutting

1. **Is an offsite copy in scope at all**, and if so with what budget?
   Options range from a second NAS at another location, through
   rclone/restic to a cloud provider, to cold-storage rotation. This is the
   largest gap in the document and the answer is a policy decision.
2. **Does surveillance footage warrant offsite capacity?** About 2 TB, and
   the reason Frigate is absent from the sequencing table.

---

## Part 9 -- What landed for item 1

Branch `backup-verification`. This section is the record of what was actually
built, so a future reader does not have to reverse-engineer it from the diff.

### The approach, and why it is not a deadman

Part 5 proposed two mechanisms and recommended both: a deadman ping (catches
"did not run") and a freshness metric (catches "ran and produced garbage").

**Only the freshness metric was built, and deliberately so.** The deadman half
depends on an unanswered question -- whether the NAS can reach healthchecks.io
outbound -- and on decisions about the NAS's own cron jobs, which are outside
this repo. Building the half that is fully answerable inside the flake, and
leaving a clean boundary, is better than blocking both on an unknown.

The freshness metric is also the stronger of the two. A deadman proves a job
started; a freshness metric proves an artifact exists, is recent, is non-empty
and is being culled. It catches the zero-byte-dump case, which a ping
structurally cannot.

### Files

| File                                                                  | Role                                                            |
| --------------------------------------------------------------------- | --------------------------------------------------------------- |
| `modules/monitoring/agent/backup-freshness.nix`                       | New. Shared module: `services.backupFreshness.artifacts.<name>` |
| `modules/monitoring/agent/default.nix`                                | Imports the above                                               |
| `modules/monitoring/master/alert-rules/backup-alerts.yaml`            | New. 8 alert rules                                              |
| `modules/monitoring/master/alert-rules/tests/backup-alerts-test.yaml` | New. 18 promtool cases                                          |
| `modules/monitoring/master/prometheus.nix`                            | Declares the snapshot artifact; two bug fixes (below)           |
| `hosts/linux/fredvps/discord-backup.nix`                              | Declares the Discord dump artifact                              |

### Metrics

All per-artifact metrics carry a `backup` label plus the `hostname` the node
job already attaches. Verified against `promtool check metrics`.

| Metric                                     | Meaning                                  |
| ------------------------------------------ | ---------------------------------------- |
| `backup_artifact_newest_timestamp_seconds` | mtime of the newest backup               |
| `backup_artifact_newest_size_bytes`        | Size of the newest backup                |
| `backup_artifact_files`                    | Number of backups present                |
| `backup_artifact_max_age_seconds`          | Declared age limit (the alert threshold) |
| `backup_artifact_min_files`                | Declared floor                           |
| `backup_artifact_max_files`                | Declared ceiling, or -1 when unset       |
| `backup_artifact_scrape_success`           | Whether the directory could be scanned   |
| `backup_freshness_timestamp_seconds`       | Per-host generator liveness              |

Two design points worth keeping:

- **The threshold is a series, not a constant in the rule.** Artifacts have
  different cadences, so `BackupArtifactStale` compares each against its own
  published limit using `on (hostname, backup) group_left ()` -- the same idiom
  `SmartAvailableSpareLow` already uses. One rule stays correct as artifacts are
  added, and the threshold is visible in Prometheus rather than buried in YAML.
- **`scrape_success` guards every data rule.** A missing directory writes the
  timestamp as 0, which makes `time() - 0` an enormous age. Without the guard, a
  bad path would be reported as a stalled backup job. `BackupArtifactScanFailing`
  carries that case instead, and a promtool case pins the behaviour.

### Two bugs found and fixed in passing

**`createPrometheusSnapshot` could report success while doing nothing.** The
`curl` had no `-f`, so any HTTP error still exited 0. Since the endpoint only
exists while `--web.enable-admin-api` is set, dropping that flag -- as the
audit's item 1.5 proposed before its premise was corrected -- would have left
the unit green, the snapshots frozen, and the NAS faithfully mirroring a stale
copy. Now uses `-sf` plus a check that the response actually contains a
snapshot name.

This is worth dwelling on: it was live, in the one job the fleet already had,
and it is precisely the false-signal class this whole item exists to remove.

**The snapshot and prune timers raced.** Both were `OnCalendar = "daily"` with
no jitter, so they fired together at 00:00. Now `00:00 +5m` for the prune and
`00:10 +5m` for the snapshot: prune first to free space, then snapshot into it,
with no overlap and ~3h45m of slack before the NAS pulls.

### Verification performed

- `promtool check rules` on all 11 rule files: pass.
- `promtool test rules` on all 9 test files, 18 new cases: pass.
- `promtool check metrics` against real generator output: exit 0. This caught
  a genuine naming defect -- `_count` is reserved for histograms and summaries,
  so the count metrics were renamed to `_files`.
- The generated shell was **extracted from the store and executed** against
  fixtures, not merely evaluated: a realistic Discord directory (confirming
  `.part` files are excluded from the count), a hardlinked TSDB snapshot tree
  (confirming `du -sb` reports 8 MB rather than the 4 KB a `stat` would, and
  that `-maxdepth 1` does not descend into blocks), a missing directory
  (`scrape_success=0`), and an empty directory (`scrape_success=1`, `files=0`).
- The `maxCount < minCount` assertion was proven to fire via `extendModules`
  with `mkForce`, rather than assumed.
- `nix eval` on all 10 Linux hosts (the change is `GLOBAL` by CI
  classification): pass, no evaluation warnings.
- Flake checks `prometheus-alert-rules`, `module-reachability`, `option-schema`,
  `doc-drift`, `input-category-sync`, `sops-recipients`, `decoder-units-sync`,
  and the full `pre-commit-check` suite: pass.
- `scripts/check-alert-metrics.sh` reports the 8 new metrics as MISSING, which
  is expected pre-deploy and stated as such by the script itself. Nothing
  previously resolving regressed. **Re-run this after deploying sdrhub and
  fredvps** -- it should resolve all 8.

### The boundary, restated

This proves the artifacts are produced. It proves nothing about the NAS.

Concretely: if the NAS's 0000 cron were deleted tonight, every alert here would
stay silent and the board would stay green, because sdrhub would still be
writing perfectly good snapshots. Closing that gap needs either a ping from the
NAS's own jobs or a fleet-side probe of the NAS, and both are still open
questions in Part 8.
