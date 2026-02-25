#!/usr/bin/env bash
# acarshub-db-repair.sh
#
# Repairs bloated acarshub SQLite databases by:
#   1. Stopping both acarshub containers
#   2. Dropping the FTS5 triggers and table (eliminates tombstone write amplification)
#   3. Deleting messages older than MSG_DAYS and alert_matches older than ALERT_DAYS
#   4. VACUUMing the database (reclaims freed pages, rewrites the file)
#   5. Recreating the FTS5 virtual table and all three triggers
#   6. Rebuilding the FTS5 index from the retained messages
#   7. Restarting both containers
#
# Must be run as root (acarshubv4 data is root-owned; systemctl needs root).
#
# Expected runtime: 30-90 minutes depending on how much data remains after pruning.
# Disk space needed: up to ~10 GB of free space for the VACUUM temp file.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

MSG_DAYS=90
ALERT_DAYS=360

ACARSHUB_DB="/opt/adsb/data/acarshub/messages.db"
ACARSHUBV4_DB="/opt/adsb/data/acarshubv4/messages.db"

ACARSHUB_BACK="/opt/adsb/data/acarshub/messages.db.back"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() {
    echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2
    exit 1
}

require_root() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root (try: sudo $0)"
}

db_size() {
    du -sh "$1" 2>/dev/null | cut -f1
}

run_sqlite() {
    local db="$1"
    local sql_file="$2"
    # Redirect stdin from the outer shell so nix-shell passes it through to sqlite3.
    # Do NOT embed the file path inside the --run string — that puts the redirection
    # inside nix-shell's subshell where quoting rules differ.
    nix-shell -p sqlite --run "sqlite3 '${db}'" <"${sql_file}"
}

# ---------------------------------------------------------------------------
# SQL generator
# ---------------------------------------------------------------------------

# Writes the full repair SQL for a database to a temp file and prints its path.
# The caller is responsible for removing it.
write_repair_sql() {
    local msg_cutoff=$(($(date +%s) - MSG_DAYS * 86400))
    local alert_cutoff=$(($(date +%s) - ALERT_DAYS * 86400))

    local tmp
    tmp=$(mktemp /tmp/acarshub-repair-XXXXXX)

    cat >"$tmp" <<ENDSQL
-- -----------------------------------------------------------------------
-- Phase 1: Remove FTS5 so that subsequent DELETEs are plain B-tree ops
--          with no per-row tombstone writes into the 4 GB FTS5 shadow tables.
-- -----------------------------------------------------------------------
DROP TRIGGER IF EXISTS messages_fts_insert;
DROP TRIGGER IF EXISTS messages_fts_delete;
DROP TRIGGER IF EXISTS messages_fts_update;
DROP TABLE  IF EXISTS messages_fts;

-- -----------------------------------------------------------------------
-- Phase 2: Prune old data
-- -----------------------------------------------------------------------
DELETE FROM messages
 WHERE msg_time < ${msg_cutoff};

DELETE FROM alert_matches
 WHERE matched_at < ${alert_cutoff};

-- -----------------------------------------------------------------------
-- Phase 3: VACUUM — rewrites the database file containing only live pages.
--          Temporarily needs up to ~10 GB of extra disk space.
-- -----------------------------------------------------------------------
VACUUM;

-- -----------------------------------------------------------------------
-- Phase 4: Recreate FTS5 virtual table
-- -----------------------------------------------------------------------
CREATE VIRTUAL TABLE messages_fts USING fts5(
  message_type  UNINDEXED,
  msg_time,
  station_id    UNINDEXED,
  toaddr        UNINDEXED,
  fromaddr      UNINDEXED,
  depa,
  dsta,
  eta           UNINDEXED,
  gtout         UNINDEXED,
  gtin          UNINDEXED,
  wloff         UNINDEXED,
  wlin          UNINDEXED,
  lat           UNINDEXED,
  lon           UNINDEXED,
  alt           UNINDEXED,
  msg_text,
  tail,
  flight,
  icao,
  freq,
  ack           UNINDEXED,
  mode          UNINDEXED,
  label,
  block_id      UNINDEXED,
  msgno         UNINDEXED,
  is_response   UNINDEXED,
  is_onground   UNINDEXED,
  error         UNINDEXED,
  libacars      UNINDEXED,
  level         UNINDEXED,
  content=messages,
  content_rowid=id
);

-- -----------------------------------------------------------------------
-- Phase 5: Recreate triggers
-- -----------------------------------------------------------------------
CREATE TRIGGER messages_fts_insert AFTER INSERT ON messages
BEGIN
  INSERT INTO messages_fts (
    rowid, message_type, msg_time, station_id, toaddr, fromaddr,
    depa, dsta, eta, gtout, gtin, wloff, wlin, lat, lon, alt,
    msg_text, tail, flight, icao, freq, ack, mode, label,
    block_id, msgno, is_response, is_onground, error, libacars, level
  ) VALUES (
    new.id, new.message_type, new.msg_time, new.station_id, new.toaddr, new.fromaddr,
    new.depa, new.dsta, new.eta, new.gtout, new.gtin, new.wloff, new.wlin,
    new.lat, new.lon, new.alt, new.msg_text, new.tail, new.flight, new.icao,
    new.freq, new.ack, new.mode, new.label, new.block_id, new.msgno,
    new.is_response, new.is_onground, new.error, new.libacars, new.level
  );
END;

CREATE TRIGGER messages_fts_delete AFTER DELETE ON messages
BEGIN
  INSERT INTO messages_fts (
    messages_fts, rowid, message_type, msg_time, station_id, toaddr, fromaddr,
    depa, dsta, eta, gtout, gtin, wloff, wlin, lat, lon, alt,
    msg_text, tail, flight, icao, freq, ack, mode, label,
    block_id, msgno, is_response, is_onground, error, libacars, level
  ) VALUES (
    'delete', old.id, old.message_type, old.msg_time, old.station_id, old.toaddr, old.fromaddr,
    old.depa, old.dsta, old.eta, old.gtout, old.gtin, old.wloff, old.wlin,
    old.lat, old.lon, old.alt, old.msg_text, old.tail, old.flight, old.icao,
    old.freq, old.ack, old.mode, old.label, old.block_id, old.msgno,
    old.is_response, old.is_onground, old.error, old.libacars, old.level
  );
END;

CREATE TRIGGER messages_fts_update AFTER UPDATE ON messages
BEGIN
  INSERT INTO messages_fts (
    messages_fts, rowid, message_type, msg_time, station_id, toaddr, fromaddr,
    depa, dsta, eta, gtout, gtin, wloff, wlin, lat, lon, alt,
    msg_text, tail, flight, icao, freq, ack, mode, label,
    block_id, msgno, is_response, is_onground, error, libacars, level
  ) VALUES (
    'delete', old.id, old.message_type, old.msg_time, old.station_id, old.toaddr, old.fromaddr,
    old.depa, old.dsta, old.eta, old.gtout, old.gtin, old.wloff, old.wlin,
    old.lat, old.lon, old.alt, old.msg_text, old.tail, old.flight, old.icao,
    old.freq, old.ack, old.mode, old.label, old.block_id, old.msgno,
    old.is_response, old.is_onground, old.error, old.libacars, old.level
  );
  INSERT INTO messages_fts (
    rowid, message_type, msg_time, station_id, toaddr, fromaddr,
    depa, dsta, eta, gtout, gtin, wloff, wlin, lat, lon, alt,
    msg_text, tail, flight, icao, freq, ack, mode, label,
    block_id, msgno, is_response, is_onground, error, libacars, level
  ) VALUES (
    new.id, new.message_type, new.msg_time, new.station_id, new.toaddr, new.fromaddr,
    new.depa, new.dsta, new.eta, new.gtout, new.gtin, new.wloff, new.wlin,
    new.lat, new.lon, new.alt, new.msg_text, new.tail, new.flight, new.icao,
    new.freq, new.ack, new.mode, new.label, new.block_id, new.msgno,
    new.is_response, new.is_onground, new.error, new.libacars, new.level
  );
END;

-- -----------------------------------------------------------------------
-- Phase 6: Rebuild FTS5 index from the retained messages
-- -----------------------------------------------------------------------
INSERT INTO messages_fts(messages_fts) VALUES('rebuild');
ENDSQL

    echo "$tmp"
}

# ---------------------------------------------------------------------------
# Per-database repair
# ---------------------------------------------------------------------------

repair_database() {
    local db="$1"
    local label="$2"

    log "--- $label ---"

    [[ -f "$db" ]] || die "Database not found: $db"

    local size_before
    size_before=$(db_size "$db")
    log "$label: size before = $size_before"

    log "$label: writing repair SQL..."
    local sql_file
    sql_file=$(write_repair_sql)
    # shellcheck disable=SC2064
    trap "rm -f '$sql_file'" RETURN

    log "$label: running Phase 1-2 (drop FTS5, prune old messages)..."
    log "$label: running Phase 3 (VACUUM — this may take 10-30 minutes)..."
    log "$label: running Phase 4-5 (recreate FTS5 table and triggers)..."
    log "$label: running Phase 6 (rebuild FTS5 index — this may take several minutes)..."

    # Run everything in one sqlite3 invocation so the connection stays open
    # and no other process can sneak in between phases.
    if run_sqlite "$db" "$sql_file"; then
        local size_after
        size_after=$(db_size "$db")
        log "$label: DONE. size before = $size_before  →  after = $size_after"
    else
        die "$label: sqlite3 exited with an error. Check output above."
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

require_root

log "========================================"
log "acarshub database repair"
log "  MSG_DAYS   = $MSG_DAYS"
log "  ALERT_DAYS = $ALERT_DAYS"
log "========================================"

# Ensure we restart containers even if something goes wrong mid-repair.
containers_started=false
restart_containers() {
    if [[ "$containers_started" == "false" ]]; then
        log "Restarting containers..."
        systemctl start docker-acarshub || log "WARNING: failed to start docker-acarshub"
        systemctl start docker-acarshubv4 || log "WARNING: failed to start docker-acarshubv4"
        containers_started=true
    fi
}
trap restart_containers EXIT

# ---------------------------------------------------------------------------
log "Stopping containers..."
systemctl stop docker-acarshub
log "  docker-acarshub stopped"
systemctl stop docker-acarshubv4
log "  docker-acarshubv4 stopped"

# Give the containers a moment to release their WAL locks.
sleep 3

# ---------------------------------------------------------------------------
# Remove the leftover backup file that is wasting 5.6 GB
if [[ -f "$ACARSHUB_BACK" ]]; then
    log "Removing leftover backup file: $ACARSHUB_BACK ($(db_size "$ACARSHUB_BACK"))"
    rm -f "$ACARSHUB_BACK"
    log "  Removed."
fi

# ---------------------------------------------------------------------------
repair_database "$ACARSHUB_DB" "acarshub"
repair_database "$ACARSHUBV4_DB" "acarshubv4"

# ---------------------------------------------------------------------------
log "Starting containers..."
systemctl start docker-acarshub
log "  docker-acarshub started"
systemctl start docker-acarshubv4
log "  docker-acarshubv4 started"
containers_started=true

log "========================================"
log "Repair complete."
log "Final disk usage:"
df -h /opt/adsb/data/
log "Database sizes:"
du -sh /opt/adsb/data/acarshub/messages.db 2>/dev/null || true
du -sh /opt/adsb/data/acarshubv4/messages.db 2>/dev/null || true
log "========================================"
