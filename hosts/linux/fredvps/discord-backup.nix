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
_: {
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
      };

      script = ''
        while [ -e /mnt/discord/discord_db.sqlite-journal ]; do
                sleep 5
        done

        cp /mnt/discord/discord_db.sqlite /mnt/discord-storage/backups/discord_db-$(date +"%Y-%m-%d-%H%M").sqlite


        find /mnt/discord-storage/backups -mtime +30 -type f -delete
      '';
    };

    timers.discord-db-backup = {
      description = "Nightly discord bot DB backup";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # Equivalent to cron's "0 1 * * *"
        OnCalendar = "*-*-* 01:00:00";
        Persistent = true;
      };
    };
  };
}
