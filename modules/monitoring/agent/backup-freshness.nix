# Freshness, size and retention metrics for on-disk backup artifacts.
#
# WHY THIS EXISTS
#
# Every backup in this fleet was, until this module, unverified. The three
# rsync jobs that pull to the NAS and the two jobs that produce what they pull
# had no metric, no alert and no deadman between them. A stopped timer, a full
# disk, a broken SSH key and a perfectly healthy night all produced the same
# observable state: nothing.
#
# That is the worst shape a backup can have, because it is indistinguishable
# from a working one until the moment someone needs a restore. See
# BACKUP-DESIGN.md Part 5.
#
# WHAT THIS DOES AND DOES NOT PROVE
#
# Read this before trusting the alerts, because the scope is narrower than
# "backups are fine" and the difference matters.
#
# This module watches artifacts ON THE HOST THAT PRODUCES THEM. It proves:
#
#   * the producing job ran recently          (newest_timestamp_seconds)
#   * it produced something non-empty         (newest_size_bytes)
#   * retention is working in both directions (count)
#
# It does NOT prove that the NAS successfully pulled any of it. A source-side
# metric cannot see the destination. The pull is a separate failure domain and
# needs either a ping from the NAS's own cron jobs or a probe of the NAS from
# the fleet -- both are open questions in BACKUP-DESIGN.md Part 8 and neither
# is closed here. Do not read a green board as "the backup is offsite".
#
# WHY A SHARED MODULE AND NOT TWO COPIES
#
# The artifacts live on different hosts (Prometheus snapshots on sdrhub, the
# Discord dumps on fredvps) and more are coming when the ADSB SQLite dumps
# land. Copying a scan script per host would mean the fix for any bug in it
# has to be applied in as many places as there are backups. The declaration is
# per-host; the implementation is shared.
#
# WHY THE THRESHOLD IS A SERIES AND NOT A CONSTANT IN THE RULE
#
# The artifacts have genuinely different cadences: the Prometheus snapshot is
# daily, the Discord dump is nightly, and anything added later may not be
# either. A single hardcoded age in the alert expression would be wrong for
# all but one of them.
#
# So each artifact publishes its own limit as backup_artifact_max_age_seconds
# and the rule compares against it with `on (hostname, backup) group_left ()`.
# This is the same idiom smart-alerts.yaml already uses for
# SmartAvailableSpareLow, which compares each drive against the threshold that
# drive itself reports rather than against a constant that is wrong for two of
# the six. One rule, correct per artifact, and the threshold is visible in
# Prometheus rather than buried in a rule file.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.backupFreshness;

  artifactModule = {
    options = {
      path = lib.mkOption {
        type = lib.types.str;
        example = "/mnt/discord-storage/backups";
        description = ''
          Directory to scan. Not a glob -- the directory itself, with
          {option}`pattern` selecting entries inside it.

          A missing directory is reported as a scrape failure rather than as
          "zero backups", because the two have different causes: the former is
          usually a bad path or an unmounted volume, the latter is a job that
          is not running.
        '';
      };

      pattern = lib.mkOption {
        type = lib.types.str;
        default = "*";
        example = "discord_db-*.sqlite";
        description = ''
          `find -name` pattern selecting the backup entries inside
          {option}`path`. Keep it tight enough to exclude in-progress work:
          the Discord job writes `.part` files that must not be counted as
          backups, and `*.sqlite` excludes them naturally.
        '';
      };

      kind = lib.mkOption {
        type = lib.types.enum [
          "file"
          "directory"
        ];
        default = "file";
        description = ''
          Whether each backup is one file or one directory.

          Prometheus TSDB snapshots are directories, so their size is the sum
          of the tree rather than one `stat`. Getting this wrong reports a
          directory's inode size (a few kilobytes) as the backup size, which
          would make the empty-artifact alert fire permanently.
        '';
      };

      maxAgeSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        example = 108000;
        description = ''
          How old the newest backup may be before BackupArtifactStale fires.

          Set this to the job's period plus real slack, not to the period
          itself. A daily job whose threshold is exactly 86400 alerts on any
          jitter, timer catch-up after a reboot, or a run that merely took
          longer than usual -- and an alert that cries wolf on healthy nights
          is worse than no alert, because it gets muted.
        '';
      };

      minCount = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 1;
        description = ''
          Fewest backups that should exist. Fires BackupArtifactMissing below
          this.

          Defaults to 1, which only catches "there are none at all". Raise it
          for artifacts where the retention policy itself is the thing being
          asserted.
        '';
      };

      maxCount = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = ''
          Most backups that should exist, or null to not check.

          This is the half of retention everyone forgets. Culling that stops
          working does not look like a fault -- it looks like more backups,
          right up until the volume fills and every job on the box starts
          failing at once. Worth setting wherever a retention sweep exists,
          which is everywhere in this fleet.
        '';
      };

      description = lib.mkOption {
        type = lib.types.str;
        description = ''
          Human-readable name for what this backup protects. Should say what
          would be lost, since that is the question being asked when the alert
          fires at 03:00.

          Published as a `desc` label on
          `backup_artifact_newest_timestamp_seconds` rather than embedded in
          the alert rules, so the answer travels with the metric and the rules
          stay generic. Carried on one metric only: repeating it across all
          seven would multiply series cardinality for no gain, and would break
          the `on (hostname, backup)` joins in the rules, which require the two
          sides to agree on exactly those labels.
        '';
      };
    };
  };

  # Written as one file per host rather than one per artifact. The textfile
  # collector has no concept of expiry, so a per-artifact file would leave a
  # stale copy behind forever if an artifact were ever removed from the
  # declaration -- a known trap this repo has hit before, documented at
  # modules/monitoring/agent/node_exporter.nix:409-416. One file that is
  # rewritten wholesale every run cannot drift that way.
  outFile = "backup_freshness.prom";

  # Emitted per artifact by the scan loop below. Kept as a Nix list so the
  # generated shell is a flat sequence of assignments rather than a loop over
  # an associative array, which keeps it readable in `systemctl cat`.
  scanArtifact =
    name: a:
    let
      findType = if a.kind == "directory" then "d" else "f";
    in
    ''
      scan_artifact ${lib.escapeShellArg name} ${lib.escapeShellArg a.path} \
        ${lib.escapeShellArg a.pattern} ${findType} \
        ${toString a.maxAgeSeconds} ${toString a.minCount} \
        ${if a.maxCount == null then "-1" else toString a.maxCount} \
        ${lib.escapeShellArg a.description}
    '';

  # This module is imported by every agent (via profiles/adsb-hub.nix) and by
  # sdrhub, which is also the monitoring master. ruleFiles is a listOf and
  # merges across modules, so the alerts can be registered here -- next to the
  # metrics they consume -- rather than in ../master/prometheus.nix. Gating on
  # services.prometheus.enable is what makes that safe: only sdrhub enables
  # Prometheus, so only sdrhub contributes the entry.
  #
  # Deliberately NOT gated on this host declaring artifacts. The absent() rules
  # in that file exist precisely to catch a host whose generator was never
  # deployed, which cannot work if the rules are only registered when the
  # generator is present. Same reasoning and structure as smartctl.nix.
  isMaster = config.services.prometheus.enable;
in
{
  options.services.backupFreshness = {
    enable = lib.mkEnableOption "backup artifact freshness metrics";

    artifacts = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule artifactModule);
      default = { };
      description = ''
        Backup artifacts to watch on this host, keyed by the value of the
        `backup` label in the emitted metrics.
      '';
      example = lib.literalExpression ''
        {
          discord-db = {
            path = "/mnt/discord-storage/backups";
            pattern = "discord_db-*.sqlite";
            maxAgeSeconds = 108000;
            maxCount = 3;
            description = "Discord bot SQLite database";
          };
        }
      '';
    };
  };

  config = lib.mkMerge [
    (lib.mkIf isMaster {
      services.prometheus.ruleFiles = [
        ../master/alert-rules/backup-alerts.yaml
      ];
    })

    (lib.mkIf (cfg.enable && cfg.artifacts != { }) {
      assertions = [
        {
          assertion = config.services.prometheus.exporters.node.enable;
          message = ''
            services.backupFreshness is enabled on ${config.networking.hostName}
            but services.prometheus.exporters.node is not.

            This module publishes its metrics through node_exporter's textfile
            collector. Without the exporter running, the .prom file is written
            on schedule and read by nothing, so every backup would appear
            unmonitored while looking configured -- the exact false-signal shape
            this module exists to remove.
          '';
        }
      ]
      ++ lib.mapAttrsToList (name: a: {
        assertion = a.maxCount == null || a.maxCount >= a.minCount;
        message = ''
          services.backupFreshness.artifacts.${name} has maxCount
          (${toString a.maxCount}) below minCount (${toString a.minCount}).

          No file count can satisfy both, so BackupArtifactMissing and
          BackupArtifactPilingUp would alternate or fire together forever.
        '';
      }) cfg.artifacts;

      systemd = {
        services.backup-freshness-metric = {
          description = "Emit backup artifact freshness metrics";

          # No sandboxing, matching every other textfile generator in this
          # fleet: the unit has to write into the root-owned directory
          # node_exporter reads, and it has to stat paths owned by other users
          # (/mnt/discord-storage is nik:users, the Prometheus snapshots are
          # prometheus:prometheus). See node_exporter.nix and home-ip-drift.nix.
          serviceConfig = {
            Type = "oneshot";
            ExecStart = pkgs.writeShellScript "backup-freshness-metric.sh" ''
              set -uo pipefail

              export PATH=${
                lib.makeBinPath [
                  pkgs.coreutils
                  pkgs.findutils
                ]
              }

              TEXTFILE_DIR=/var/lib/node_exporter/textfiles
              OUT="$TEXTFILE_DIR/${outFile}"
              TMP="$OUT.$$"

              mkdir -p "$TEXTFILE_DIR"

              # Header written once, then one block per artifact appended. The
              # textfile collector rejects a whole file if any single sample is
              # malformed, so every value below is either produced by stat/find
              # or is a literal integer from the Nix declaration.
              {
                echo "# HELP backup_artifact_newest_timestamp_seconds Unix mtime of the newest backup for this artifact."
                echo "# TYPE backup_artifact_newest_timestamp_seconds gauge"
                echo "# HELP backup_artifact_newest_size_bytes Size in bytes of the newest backup for this artifact."
                echo "# TYPE backup_artifact_newest_size_bytes gauge"
                echo "# HELP backup_artifact_files Number of backup entries (files or directories) present for this artifact."
                echo "# TYPE backup_artifact_files gauge"
                echo "# HELP backup_artifact_max_age_seconds Configured age limit before this artifact is considered stale."
                echo "# TYPE backup_artifact_max_age_seconds gauge"
                echo "# HELP backup_artifact_min_files Configured minimum number of backups for this artifact."
                echo "# TYPE backup_artifact_min_files gauge"
                echo "# HELP backup_artifact_max_files Configured maximum number of backups, or -1 when unset."
                echo "# TYPE backup_artifact_max_files gauge"
                echo "# HELP backup_artifact_scrape_success Whether this artifact's directory could be scanned."
                echo "# TYPE backup_artifact_scrape_success gauge"
              } > "$TMP"

              scan_artifact() {
                local name="$1" path="$2" pattern="$3" ftype="$4"
                local max_age="$5" min_count="$6" max_count="$7" desc="$8"

                local newest_ts=0 newest_size=0 count=0 ok=0

                if [ -d "$path" ]; then
                  # -maxdepth 1 so a snapshot directory's own contents are never
                  # mistaken for additional snapshots. -printf '%T@' gives the
                  # mtime as a number we can sort on without parsing dates.
                  #
                  # 2>/dev/null on find, not on the whole pipeline: an
                  # unreadable subdirectory should not turn a successful scan
                  # into a failed one, but a genuinely absent path must (see the
                  # -d test above, which is what distinguishes them).
                  local newest
                  newest=$(find "$path" -maxdepth 1 -mindepth 1 \
                             -type "$ftype" -name "$pattern" \
                             -printf '%T@ %p\n' 2>/dev/null \
                           | sort -rn | head -n1)

                  count=$(find "$path" -maxdepth 1 -mindepth 1 \
                            -type "$ftype" -name "$pattern" \
                            2>/dev/null | wc -l)

                  ok=1

                  if [ -n "$newest" ]; then
                    # %T@ is a float (seconds.fraction). Prometheus accepts
                    # floats, but an integer keeps the age arithmetic in the
                    # alert exact and matches every other timestamp metric in
                    # this fleet.
                    newest_ts=''${newest%%.*}

                    local newest_path="''${newest#* }"
                    if [ "$ftype" = "d" ]; then
                      # Apparent size, summed over the tree, in bytes. -b
                      # implies --apparent-size, which is the right measure
                      # here: Prometheus snapshots are hardlink farms, so disk
                      # usage would report almost nothing for a complete
                      # snapshot and the empty-artifact alert would fire on a
                      # perfectly good backup.
                      newest_size=$(du -sb "$newest_path" 2>/dev/null | cut -f1)
                    else
                      newest_size=$(stat -c '%s' "$newest_path" 2>/dev/null)
                    fi

                    # stat and du can still fail on a file that vanished
                    # between the find and the stat -- a nightly job rotating
                    # exactly as this runs. Treat that as a successful scan
                    # reporting zero size rather than emitting an empty string,
                    # which would make the whole textfile invalid.
                    [ -n "$newest_size" ] || newest_size=0
                  fi
                fi

                {
                  # desc rides along on this one metric only. See the option's
                  # own documentation: putting it on all seven would break the
                  # `on (hostname, backup)` joins the alert rules depend on.
                  printf 'backup_artifact_newest_timestamp_seconds{backup="%s",desc="%s"} %s\n' "$name" "$desc" "$newest_ts"
                  printf 'backup_artifact_newest_size_bytes{backup="%s"} %s\n' "$name" "$newest_size"
                  printf 'backup_artifact_files{backup="%s"} %s\n' "$name" "$count"
                  printf 'backup_artifact_max_age_seconds{backup="%s"} %s\n' "$name" "$max_age"
                  printf 'backup_artifact_min_files{backup="%s"} %s\n' "$name" "$min_count"
                  printf 'backup_artifact_max_files{backup="%s"} %s\n' "$name" "$max_count"
                  printf 'backup_artifact_scrape_success{backup="%s"} %s\n' "$name" "$ok"
                } >> "$TMP"
              }

              ${lib.concatStrings (lib.mapAttrsToList scanArtifact cfg.artifacts)}

              {
                # The generator's own liveness. Without this, a unit that stops
                # running leaves every metric above frozen at its last healthy
                # value, and the board stays green forever -- the same failure
                # HomePublicIPCheckStale exists to catch.
                echo "# HELP backup_freshness_timestamp_seconds Unix time this file was last written."
                echo "# TYPE backup_freshness_timestamp_seconds gauge"
                printf 'backup_freshness_timestamp_seconds %s\n' "$(date +%s)"
              } >> "$TMP"

              # Atomic replace: node_exporter reads this directory on every
              # scrape and must never see a partially written file.
              mv "$TMP" "$OUT"
            '';
          };
        };

        timers.backup-freshness-metric = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            # Every 15 minutes. The artifacts change at most daily, so this is
            # far more often than the events being watched -- deliberately, so
            # that the series recovers quickly after a reboot and so the
            # generator's own staleness alert has a tight signal to work with.
            # The scan is a bounded `find -maxdepth 1` over a handful of
            # entries, so the cost is negligible.
            OnBootSec = "5min";
            OnUnitActiveSec = "15min";
            AccuracySec = "30s";
            Persistent = true;
          };
        };
      };
    })
  ];
}
