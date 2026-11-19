#!/usr/bin/env bash
#
# systemd-user-units.sh -- export failed systemd USER units for
# node_exporter's textfile collector.
#
# node_exporter's systemd collector only talks to the system manager, so a
# failed user unit is invisible to it. autotrash.service (a home-manager user
# unit) failed every day for months on Daytona, corehub and adsbhub without
# anything noticing. This asks every running user manager directly.
#
# Series (hostname/role come from the scrape):
#
#   node_systemd_user_unit_failed{user,name}        1 per failed unit
#   node_systemd_user_units_failed{user}            count, 0 included
#   node_systemd_user_manager_up{user}              1 if the manager answered
#   node_systemd_user_units_collector_ok            0 if users could not be listed
#   node_systemd_user_units_timestamp_seconds       when this file was written
#
# The per-user and collector series are written on every run, including
# failures, so "no failed units" is always a 0 and never an absence.
#
# Run as root (it needs `systemctl --user -M <user>@`). TEXTFILE_DIR overrides
# the output directory for tests.

set -uo pipefail
export LC_ALL=C

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfiles}"
OUT="$TEXTFILE_DIR/systemd_user_units.prom"

mkdir -p "$TEXTFILE_DIR"
TMP="$(mktemp "$OUT.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

# Prometheus text-format label escaping: backslash, double quote, newline.
esc() {
  local s="${1//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "${s//$'\n'/\\n}"
}

failed_lines=()
count_lines=()
up_lines=()

COLLECTOR_OK=1
users=""
if users_json="$(loginctl list-users --json=short 2>/dev/null)" &&
  users="$(jq -r '.[].user' <<<"$users_json" 2>/dev/null)"; then
  :
else
  COLLECTOR_OK=0
  users=""
fi

while IFS= read -r user; do
  [[ -n "$user" ]] || continue
  u="$(esc "$user")"
  if units_json="$(systemctl --user -M "$user@" list-units --all --state=failed -o json --no-pager 2>/dev/null)" &&
    units="$(jq -r '.[] | select(.active == "failed") | .unit' <<<"$units_json" 2>/dev/null)"; then
    up_lines+=("node_systemd_user_manager_up{user=\"$u\"} 1")
    n=0
    while IFS= read -r unit; do
      [[ -n "$unit" ]] || continue
      failed_lines+=("node_systemd_user_unit_failed{user=\"$u\",name=\"$(esc "$unit")\"} 1")
      n=$((n + 1))
    done <<<"$units"
    count_lines+=("node_systemd_user_units_failed{user=\"$u\"} $n")
  else
    # Unknown, not zero: no count series for this user this run.
    up_lines+=("node_systemd_user_manager_up{user=\"$u\"} 0")
  fi
done <<<"$users"

{
  echo "# HELP node_systemd_user_unit_failed A systemd user unit that is in the failed state (1 per unit)."
  echo "# TYPE node_systemd_user_unit_failed gauge"
  [[ ${#failed_lines[@]} -eq 0 ]] || printf '%s\n' "${failed_lines[@]}"

  echo "# HELP node_systemd_user_units_failed Number of failed systemd user units, per user."
  echo "# TYPE node_systemd_user_units_failed gauge"
  [[ ${#count_lines[@]} -eq 0 ]] || printf '%s\n' "${count_lines[@]}"

  echo "# HELP node_systemd_user_manager_up Whether the user's systemd manager answered the query (0 = its failed units are unknown)."
  echo "# TYPE node_systemd_user_manager_up gauge"
  [[ ${#up_lines[@]} -eq 0 ]] || printf '%s\n' "${up_lines[@]}"

  echo "# HELP node_systemd_user_units_collector_ok Whether the user managers could be listed at all (loginctl)."
  echo "# TYPE node_systemd_user_units_collector_ok gauge"
  echo "node_systemd_user_units_collector_ok $COLLECTOR_OK"

  echo "# HELP node_systemd_user_units_timestamp_seconds Unix time this file was last written."
  echo "# TYPE node_systemd_user_units_timestamp_seconds gauge"
  echo "node_systemd_user_units_timestamp_seconds $(date +%s)"
} >"$TMP"

# Atomic replace: one invalid sample makes the textfile collector reject the
# whole file, so a half-written one must never be visible.
chmod 0644 "$TMP"
mv "$TMP" "$OUT"
trap - EXIT
