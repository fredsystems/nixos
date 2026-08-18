# Discord DB filesystem layout + nightly backup for fredvps.
#
# /mnt/discord                 — live sqlite DB directory (hardcoded path
#                                 in discord-bot/discord_db.py and
#                                 db_vacuum.py; test_site falls back to it
#                                 read-only when DATABASE_PATH isn't set).
# /mnt/discord-storage          — backup destination.
# /mnt/discord-storage/backups  — where dated backup copies land.
#
# All three are plain local directories, created once via an
# activationScript (does not touch contents if already there — same
# pattern as the adsbDockerCompose activationScript above) — how (or
# whether) /mnt/discord-storage is actually backed by something else
# (NFS, a separate disk, etc.) is handled outside this repo.
{ pkgs, ... }:
{
  system.activationScripts.discordDirs = {
    text = ''
      install -d -m0755 -o nik -g users /mnt/discord
      install -d -m0755 -o nik -g users /mnt/discord-storage
      install -d -m0755 -o nik -g users /mnt/discord-storage/backups
    '';
    deps = [ ];
  };

  systemd = {
    services.discord-db-backup = {
      description = "Backup discord bot sqlite DB";

      serviceConfig = {
        Type = "oneshot";
        User = "nik";
        Group = "users";

        # Hardening, kept deliberately conservative. This is the fleet's
        # only backup of the live Discord bot DB, it runs as a normal user
        # (not root), and it touches paths outside the Nix store and
        # outside /home (/mnt/discord, /mnt/discord-storage) -- a broken
        # nightly backup is worse than an unhardened one, so anything not
        # clearly safe is left out rather than guessed at.
        #
        # These six are pure kernel/system-namespace restrictions with no
        # dependency on which paths the script touches, so they cannot
        # interact with the sqlite3 .backup / mv / find calls above:
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;

        # Deliberately NOT set: ProtectSystem / ProtectHome.
        #
        # ProtectSystem=strict would make the filesystem read-only outside
        # an explicit ReadWritePaths allowlist, and this script needs write
        # access to *two* directories, not one: /mnt/discord-storage/backups
        # (the obvious one -- .part files, the atomic rename, the retention
        # sweep) AND, per the header comment above, potentially
        # /mnt/discord itself. The .backup API opens the live WAL-mode
        # database close to how a normal connection would, and this file's
        # own comment on the test-site config notes a WAL reader can need
        # directory write access to create -wal/-shm siblings. Getting that
        # second path wrong silently breaks the backup (or the live bot) in
        # a way that would not surface until the next restore is needed, so
        # it's left out rather than guessed at.
      };

      # WHY sqlite3 .backup AND NOT cp
      #
      # This was `cp` guarded by a wait on discord_db.sqlite-journal. Both
      # halves were wrong, because the database runs in WAL mode (see the
      # test-site notes in configuration.nix: the reader needs directory write
      # access precisely so SQLite can create -wal/-shm).
      #
      #   * WAL mode never creates a `-journal` file -- it creates `-wal` and
      #     `-shm` -- so the guard could not fire and never once waited.
      #   * `cp` copied only the main database, leaving every transaction still
      #     in the WAL out of the backup. Anything committed since the last
      #     checkpoint was silently missing.
      #   * `cp` is not atomic against a live writer. A checkpoint landing
      #     mid-copy yields a torn file, which surfaces as "database disk image
      #     is malformed" at restore time -- i.e. the one moment it matters.
      #
      # `.backup` uses SQLite's online backup API: it takes a read lock, folds
      # the WAL in, and restarts itself if a writer interferes, so the output is
      # a consistent snapshot of a real commit boundary. It is also why no
      # wait-loop is needed any more -- concurrency is the API's problem now.
      #
      # Written to a .part path and moved into place, so a name that looks like
      # a backup only ever exists once it IS one. This matters beyond local
      # tidiness: the NAS pulls this directory nightly with `rsync --delete`, so
      # a half-written file under a real backup name would be replicated and
      # counted as a good copy at both ends. NixOS runs `script` under `set -e`,
      # so a failed .backup aborts before the move.
      #
      # Stale .part files are cleared at the start rather than trusted to the
      # retention sweep, which only fires at +14 days and would leave a corpse
      # visible to the NAS for two weeks.
      #
      # VACUUM INTO would also work and would compact as it goes, which is
      # tempting at ~1 GB per copy times 14 copies. Not used here because it
      # rewrites the whole file every night, which would defeat rsync's ability
      # to delta successive backups against each other when the NAS pulls them.
      #
      # RETENTION: NEWEST ONLY, WITH THE HISTORY HELD ON THE NAS
      #
      # This was 14 days on-host, and that had become the largest single
      # consumer of a filesystem with no headroom. Measured 2026-08-18:
      #
      #   15 dumps on disk          16.66 GB
      #   newest dump alone          1.78 GiB
      #   fredvps root filesystem   74 GB total, 21 GB free (71% used)
      #
      # Everything on this host shares one filesystem, so those dumps were 22%
      # of it, and DiskFillPredicted was firing for `/` and `/nix/store` as a
      # direct result.
      #
      # Keeping ONE is not a retention cut, it is a relocation: the NAS holds
      # the history instead. The two halves are interlocked and MUST be
      # deployed together -- the NAS job's `--delete` has to go at the same
      # time, or the first pull after this change propagates the deletion and
      # leaves exactly one copy at both ends, which is strictly worse than
      # before and looks like success. See BACKUP-DESIGN.md Part 11.
      #
      # keep=1 rather than 2 or 3 because this database is growing fast: 84.7
      # MiB/day measured over the fortnight above, 2.86x in 14 days. At that
      # rate a single dump is ~4.3 GiB in 30 days and ~9.2 GiB in 90; keep=2
      # would be ~18 GiB by then, i.e. most of the free space again. One copy
      # locally is the restore-from-here path, and it is the NAS that provides
      # depth.
      #
      # Retention is by COUNT and scoped by NAME, replacing `find -mtime +14
      # -type f -delete`. Two reasons:
      #
      #   * that pattern matched ANY file in the directory, so an unrelated
      #     artifact left there was on a 14-day deletion timer. There is one
      #     such file right now -- a manually created 1.94 GB `dump.sqlite`,
      #     root-owned, which nothing in this repository creates -- and it
      #     would have been silently deleted on 2026-09-02.
      #   * count-based retention cannot be defeated by mtime changes, which
      #     matters because these files are copied around by rsync and could be
      #     restored from the NAS with fresh timestamps.
      #
      # Same shape as modules/services/sqlite-backup.nix, deliberately: that
      # module is where this logic is heading once it has proven itself here.
      script = ''
        rm -f /mnt/discord-storage/backups/*.part

        dest=/mnt/discord-storage/backups/discord_db-$(date +"%Y-%m-%d-%H%M").sqlite

        ${pkgs.sqlite}/bin/sqlite3 /mnt/discord/discord_db.sqlite \
          ".backup '$dest.part'"

        # Verify before publishing, and before the prune below removes the
        # previous good copy. A torn or truncated dump that replaced the only
        # retained backup would leave this host with no valid local copy at
        # all -- the risk is strictly higher at keep=1 than it was at 14 days,
        # so the check is not optional here.
        result=$(${pkgs.sqlite}/bin/sqlite3 "$dest.part" 'PRAGMA integrity_check;' 2>&1) || {
          echo "integrity_check could not run on $dest.part: $result" >&2
          rm -f "$dest.part"
          exit 1
        }

        if [ "$result" != "ok" ]; then
          echo "dump failed integrity_check, refusing to publish: $result" >&2
          rm -f "$dest.part"
          exit 1
        fi

        mv "$dest.part" "$dest"

        # Prune to the newest, oldest first. Runs AFTER the move, so the count
        # includes the dump just published: keep=1 means one file at rest, not
        # one plus tonight's.
        #
        # Sorted by filename, which is chronological given the timestamp
        # format, so this does not depend on mtime. Globbed on the
        # `discord_db-` prefix so nothing else in the directory is a candidate.
        ls -1 /mnt/discord-storage/backups/discord_db-*.sqlite 2>/dev/null \
          | sort -r \
          | tail -n +2 \
          | while read -r old; do
              echo "pruning $old"
              rm -f "$old"
            done
      '';
    };

    timers.discord-db-backup = {
      description = "Nightly discord bot DB backup";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # Equivalent to cron's "0 1 * * *"
        OnCalendar = "*-*-* 01:00:00";
        Persistent = true;

        # Was the fleet's only unjittered timer. 15 minutes smooths out the
        # exact-second alignment with other fixed-time daily jobs on this
        # host (e.g. docker's autoPrune) without meaningfully delaying the
        # backup relative to the NAS's nightly pull, which has hours of
        # slack after 01:00 to work with.
        RandomizedDelaySec = "15m";
      };
    };
  };

  # Verification for the backup above.
  #
  # Declared here, in the file that owns the backup, rather than centrally:
  # the metric and the thing it watches cannot then be added, moved or removed
  # separately. Same reasoning as the ruleFiles placement in blackbox.nix and
  # smartctl.nix.
  #
  # This closes a real gap rather than a theoretical one. Until now the only
  # evidence this job worked was the presence of files nobody looked at. A
  # failed `.backup` aborts the unit under `set -e` and systemd records it, but
  # nothing alerted on that, so a silently broken nightly backup would have
  # been discovered at restore time.
  #
  # NOTE the scope limit: this watches the dumps ON THIS HOST. It says nothing
  # about whether the NAS pulled them. See BACKUP-DESIGN.md.
  services.backupFreshness = {
    enable = true;
    artifacts.discord-db = {
      path = "/mnt/discord-storage/backups";

      # Excludes the `.part` files the script writes and then renames. Counting
      # those as backups would defeat the atomic-rename discipline the script
      # documents at length: a half-written dump would satisfy the freshness
      # alert precisely when it is least deserved.
      pattern = "discord_db-*.sqlite";

      # 30 hours. The timer is 01:00 plus up to 15 minutes of jitter, so a
      # healthy newest-dump age peaks a little over 24h just before each run.
      # 30h leaves real slack for a long .backup on a ~2 GB WAL-mode database
      # without waiting so long that two consecutive misses go unnoticed.
      maxAgeSeconds = 108000;

      # keep=1 in the script above, so exactly one dump is the healthy state.
      #
      # 2 rather than 1 as the ceiling, deliberately: the prune runs after the
      # publish, so a run that is interrupted between those two steps leaves
      # two files behind legitimately until the next night tidies up. Alerting
      # on that would be alerting on a transient. Anything at 3 or above means
      # the prune has genuinely stopped, which at 84.7 MiB/day of growth is
      # worth knowing about quickly -- this is the host whose filesystem these
      # dumps were filling.
      #
      # This bound is now the only thing watching local retention, since the
      # NAS holds the history and no longer mirrors a deletion.
      maxCount = 2;

      description = "Discord bot SQLite database dumps";
    };
  };
}
