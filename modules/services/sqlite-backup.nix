# Consistent point-in-time dumps of live SQLite databases.
#
# WHY THIS EXISTS
#
# The NAS pulls /opt/adsb nightly with rsync while the acarshub containers are
# running and writing. Both message databases run in WAL mode, so that copy has
# the same two defects the audit already found and fixed in
# hosts/linux/fredvps/discord-backup.nix:
#
#   * rsync copies the main database file but not a coherent view of its -wal
#     and -shm siblings, so anything committed since the last checkpoint can be
#     missing from the copy.
#   * rsync is not atomic against a live writer. A checkpoint landing mid-copy
#     yields a torn file, which surfaces as "database disk image is malformed"
#     at restore time -- the one moment it matters.
#
# SQLite's online backup API (`.backup`) takes a read lock, folds the WAL in,
# and restarts itself if a writer interferes, so its output is a consistent
# snapshot at a real commit boundary. This module runs that on a timer and
# writes the result somewhere the existing NAS pull will collect.
#
# WHY A MODULE RATHER THAN A THIRD COPY OF THE SCRIPT
#
# discord-backup.nix already does this correctly for one database, and its
# header documents the reasoning at length. Adding acarshub and acarshubv4 by
# copy-paste would mean three implementations of the same careful sequence, and
# any future fix would need finding in all three.
#
# discord-backup.nix is deliberately NOT migrated onto this module in the same
# change that introduces it: it is the fleet's only backup of a 1.9 GB database
# that has no other copy, and rewriting a working backup at the same time as
# writing the thing meant to replace it is how both end up broken. That is a
# follow-up, once this has run in production for a while.
#
# WHY NOT VACUUM INTO, AND WHY NOT COMPRESSED
#
# Both would produce smaller files -- measured on this fleet, gzip -1 takes a
# 1.41 GB dump to 0.47 GB in 14 seconds -- and both are rejected for the same
# reason discord-backup.nix rejects VACUUM INTO: the NAS pulls these with rsync
# over a slow link, and a recompressed or fully-rewritten file shares no blocks
# with last night's, so rsync has to transfer all of it every time. An
# uncompressed .backup of an append-mostly database deltas well. Disk is not
# the scarce resource here; NAS transfer time is.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.sqliteBackup;

  databaseModule = {
    options = {
      source = lib.mkOption {
        type = lib.types.str;
        example = "/opt/adsb/data/acarshub/messages.db";
        description = ''
          Absolute path to the live database. It stays open and writable
          throughout -- the backup API is designed to run against a database
          with active writers, so nothing is stopped or paused.

          Deliberately not the `-wal` or `-shm` sibling: naming the main
          database is what lets SQLite fold the WAL into the snapshot itself.
        '';
      };

      destination = lib.mkOption {
        type = lib.types.str;
        example = "/opt/adsb/backups";
        description = ''
          Directory the dumps are written to. Created if absent.

          Choose a path the off-host copy already collects. On sdrhub that
          means somewhere under /opt/adsb, because the NAS's existing nightly
          pull of that tree then picks the dumps up with no change needed at
          the NAS end.
        '';
      };

      name = lib.mkOption {
        type = lib.types.str;
        example = "acarshub-messages";
        description = ''
          Filename prefix for the dumps, which land as
          `<name>-<YYYY-MM-DD-HHMM>.sqlite`.

          Must be unique within a {option}`destination`, since retention
          globs on it -- two databases sharing a prefix would each cull the
          other's dumps.
        '';
      };

      keep = lib.mkOption {
        type = lib.types.ints.positive;
        default = 3;
        description = ''
          How many dumps to retain locally, newest first.

          Deliberately a count rather than an age. The audit's plan (see
          BACKUP-DESIGN.md Part 2) proposes moving retention to the NAS and
          keeping only the newest copy here, but that CANNOT land on its own:
          the NAS job currently passes `rsync --delete`, so a host that keeps
          one dump makes the NAS keep one dump, and the first pull after such a
          change would delete every older copy at both ends. Until the NAS side
          is changed, keeping a few here is what gives the mirror something to
          hold, and `--delete` faithfully reproduces it.

          3 is ~8.5 GB for the two acarshub databases against 288 GB free.
        '';
      };
    };
  };

  # Wrapped rather than inlined per database so the sequence exists once. Every
  # step here is load-bearing; see the comments.
  backupScript = pkgs.writeShellScript "sqlite-backup.sh" ''
    set -euo pipefail

    SQLITE=${pkgs.sqlite}/bin/sqlite3

    source="$1"
    dest_dir="$2"
    name="$3"
    keep="$4"

    if [ ! -f "$source" ]; then
      echo "source database does not exist: $source" >&2
      exit 1
    fi

    ${pkgs.coreutils}/bin/mkdir -p "$dest_dir"

    # Stale .part files are cleared up front rather than left to retention.
    # Retention counts completed dumps, so a corpse from an interrupted run
    # would otherwise sit there indefinitely, visible to the NAS pull.
    ${pkgs.findutils}/bin/find "$dest_dir" -maxdepth 1 -name "$name-*.sqlite.part" -delete

    dest="$dest_dir/$name-$(${pkgs.coreutils}/bin/date +%Y-%m-%d-%H%M).sqlite"

    # Written to .part and moved into place, so a filename that looks like a
    # backup only exists once it IS one. This matters beyond tidiness: the NAS
    # pulls this directory with --delete, so a half-written file under a real
    # backup name would be replicated and counted as a good copy at both ends.
    $SQLITE "$source" ".backup '$dest.part'"

    # Verify BEFORE publishing. A backup nobody has ever read is a hope, not a
    # backup -- AUDIT-2026-08-04.md Part 7 item 4 makes exactly this point, and
    # acarshub-db-repair.sh deleting a stale 5.6 GB backup with no replacement
    # is what that failure looks like in practice.
    #
    # integrity_check on a freshly written file is cheap (~1s per GB here) and
    # catches a truncated or torn dump while the previous good one is still the
    # newest published copy. quick_check would be faster but does not verify
    # index structure, which is where a torn FTS5 write would show up.
    if ! result=$($SQLITE "$dest.part" 'PRAGMA integrity_check;' 2>&1); then
      echo "integrity_check could not run on $dest.part: $result" >&2
      rm -f "$dest.part"
      exit 1
    fi

    if [ "$result" != "ok" ]; then
      echo "dump failed integrity_check, refusing to publish: $result" >&2
      rm -f "$dest.part"
      exit 1
    fi

    ${pkgs.coreutils}/bin/mv "$dest.part" "$dest"

    # Retention by count, newest kept. Sorted by name, which is chronological
    # given the timestamp format, so this does not depend on mtime surviving an
    # rsync or a restore.
    #
    # Runs after the move so the count includes the dump just published: with
    # keep=3 that means three dumps exist at rest, not three plus tonight's.
    ${pkgs.coreutils}/bin/ls -1 "$dest_dir/$name-"*.sqlite 2>/dev/null \
      | ${pkgs.coreutils}/bin/sort -r \
      | ${pkgs.coreutils}/bin/tail -n "+$((keep + 1))" \
      | while read -r old; do
          echo "pruning $old"
          rm -f "$old"
        done

    echo "published $dest"
  '';
in
{
  options.services.sqliteBackup = {
    enable = lib.mkEnableOption "consistent SQLite database dumps";

    databases = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule databaseModule);
      default = { };
      description = ''
        Databases to dump, keyed by systemd unit suffix. Each gets its own
        `sqlite-backup-<key>.service` and matching timer, so one database
        failing cannot stop another from being dumped.
      '';
    };

    startAt = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 00:30:00";
      description = ''
        `OnCalendar` expression for every dump timer.

        The default leaves room ahead of the NAS's 01:00 wall-clock pull of
        /opt/adsb -- note the NAS is not DST-corrected, so its scheduled 0000
        is 01:00 here during DST (see BACKUP-DESIGN.md Part 0). Each dump takes
        about 5 seconds per 1.4 GB database plus a comparable integrity check,
        so 30 minutes is ample slack for both.
      '';
    };
  };

  config = lib.mkIf (cfg.enable && cfg.databases != { }) {
    systemd.services = lib.mapAttrs' (
      key: db:
      lib.nameValuePair "sqlite-backup-${key}" {
        description = "Consistent SQLite dump of ${db.name}";

        serviceConfig = {
          Type = "oneshot";

          # Runs as root, deliberately. The two acarshub databases have
          # different owners (fred:users and root:root respectively, both
          # created by their containers), so no single unprivileged user can
          # read both, and the backup API needs write access to the source
          # database's directory to create its own -wal/-shm siblings while
          # reading.
          #
          # Hardening kept to the same conservative set as
          # discord-backup.nix, and for the same stated reason: these are pure
          # kernel and namespace restrictions that cannot interact with the
          # paths the script touches. ProtectSystem and ProtectHome are
          # deliberately omitted -- they would require getting an explicit
          # ReadWritePaths allowlist exactly right across both the source and
          # destination trees, and a silently broken nightly backup is worse
          # than an unhardened one.
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          RestrictSUIDSGID = true;
          LockPersonality = true;

          # Both databases sit around 1.4 GB and take ~20s to dump and verify.
          # A cap an order of magnitude above that turns a hung backup into a
          # failed unit -- which the freshness alerts then report -- rather
          # than a job that runs until the next one is due.
          TimeoutStartSec = "30min";

          ExecStart = "${backupScript} ${
            lib.escapeShellArgs [
              db.source
              db.destination
              db.name
              (toString db.keep)
            ]
          }";
        };
      }
    ) cfg.databases;

    systemd.timers = lib.mapAttrs' (
      key: db:
      lib.nameValuePair "sqlite-backup-${key}" {
        description = "Nightly SQLite dump of ${db.name}";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.startAt;
          Persistent = true;

          # Jitter, matching the convention the audit's item 3.4 established
          # for discord-backup.nix. It also staggers the databases against each
          # other, so two 1.4 GB dumps on the same host do not contend for the
          # same disk at the same instant.
          RandomizedDelaySec = "10m";
        };
      }
    ) cfg.databases;
  };
}
