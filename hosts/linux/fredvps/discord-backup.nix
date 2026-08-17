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
      script = ''
        rm -f /mnt/discord-storage/backups/*.part

        dest=/mnt/discord-storage/backups/discord_db-$(date +"%Y-%m-%d-%H%M").sqlite

        ${pkgs.sqlite}/bin/sqlite3 /mnt/discord/discord_db.sqlite \
          ".backup '$dest.part'"

        mv "$dest.part" "$dest"

        # Retention. Safe to run unconditionally: by here the only files present
        # are completed backups.
        find /mnt/discord-storage/backups -mtime +14 -type f -delete
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
}
