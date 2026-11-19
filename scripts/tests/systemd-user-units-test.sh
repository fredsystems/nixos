#!/usr/bin/env bash
#
# systemd-user-units-test.sh -- hermetic tests for
# modules/monitoring/agent/systemd-user-units.sh, the collector that exports
# failed systemd user units to node_exporter's textfile directory.
#
# loginctl and systemctl are replaced by fakes driven by files in a scratch
# directory, so every case (healthy, failed units, a manager that does not
# answer, loginctl itself failing, awkward unit names) runs without systemd.
# Every generated file is also run through `promtool check metrics`, because
# one malformed sample makes node_exporter drop the whole file.
#
# No network, no root, no Nix daemon: runs as a flake check
# (`.#checks.<system>.systemd-user-units`) and as a pre-commit hook.
#
# Usage: bash scripts/tests/systemd-user-units-test.sh   (from the repo root)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COLLECTOR="$ROOT/modules/monitoring/agent/systemd-user-units.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); }
bad() {
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n' "$1" >&2
    [[ $# -lt 2 ]] || printf '      %s\n' "${@:2}" >&2
}
has() { # name file line
    if grep -qxF -- "$3" "$2"; then ok; else bad "$1" "missing line: $3" "file:" "$(cat "$2")"; fi
}
lacks() { # name file regex
    if grep -qE -- "$3" "$2"; then bad "$1" "unexpected match: $3" "file:" "$(cat "$2")"; else ok; fi
}

# Fakes. $FAKE/users is loginctl's JSON (absent = loginctl fails);
# $FAKE/units.<user> is systemctl's JSON for that user (absent = fails).
FAKE="$WORK/fake"
mkdir -p "$WORK/bin"
# The running bash's absolute path: the Nix build sandbox has no /usr/bin/env.
BASH_PATH="$(command -v bash)"
{
    printf '#!%s\n' "$BASH_PATH"
    cat <<'EOF'
[[ "$*" == "list-users --json=short" ]] || exit 2
cat "$FAKE/users" 2>/dev/null
EOF
} >"$WORK/bin/loginctl"
{
    printf '#!%s\n' "$BASH_PATH"
    cat <<'EOF'
# Expect: --user -M <user>@ list-units --all --state=failed -o json --no-pager
[[ "$1" == "--user" && "$2" == "-M" && "$4 $5 $6 $7 $8 $9" == "list-units --all --state=failed -o json --no-pager" ]] || exit 2
cat "$FAKE/units.${3%@}" 2>/dev/null
EOF
} >"$WORK/bin/systemctl"
chmod +x "$WORK/bin/loginctl" "$WORK/bin/systemctl"
export PATH="$WORK/bin:$PATH" FAKE

# run CASE -> path of the .prom file written for that case
run() {
    local out="$WORK/out/$1"
    mkdir -p "$out"
    # -e: writeShellApplication runs the collector with errexit on.
    TEXTFILE_DIR="$out" bash -e "$COLLECTOR"
    printf '%s\n' "$out/systemd_user_units.prom"
}

valid() { # name file
    local err
    if err="$(promtool check metrics <"$2" 2>&1)"; then ok; else bad "$1: promtool rejects the file" "$err"; fi
}

reset() { rm -rf "$FAKE" && mkdir -p "$FAKE"; }

# ---------------------------------------------------------------------------
# Healthy host: one lingering user, nothing failed
# ---------------------------------------------------------------------------

reset
echo '[{"uid":1000,"user":"fred","linger":true,"state":"active"}]' >"$FAKE/users"
echo '[]' >"$FAKE/units.fred"
F="$(run healthy)"
valid "healthy" "$F"
has "healthy: count is an explicit 0" "$F" 'node_systemd_user_units_failed{user="fred"} 0'
has "healthy: manager up" "$F" 'node_systemd_user_manager_up{user="fred"} 1'
has "healthy: collector ok" "$F" 'node_systemd_user_units_collector_ok 1'
lacks "healthy: no per-unit series" "$F" '^node_systemd_user_unit_failed\{'
if grep -qE '^node_systemd_user_units_timestamp_seconds [0-9]+$' "$F"; then ok; else bad "healthy: timestamp written"; fi
if [[ "$(stat -c %a "$F")" == 644 ]]; then ok; else bad "healthy: file is world-readable for node_exporter"; fi

# ---------------------------------------------------------------------------
# The autotrash case, plus a second user
# ---------------------------------------------------------------------------

reset
echo '[{"uid":1000,"user":"fred","linger":true,"state":"active"},{"uid":1001,"user":"nik","linger":true,"state":"lingering"}]' >"$FAKE/users"
cat >"$FAKE/units.fred" <<'EOF'
[{"unit":"autotrash.service","load":"loaded","active":"failed","sub":"failed","description":"Empty Trash"},
 {"unit":"mnt-nas\\x2dmedia.mount","load":"loaded","active":"failed","sub":"failed","description":"NAS"}]
EOF
echo '[]' >"$FAKE/units.nik"
F="$(run failed)"
valid "failed" "$F"
has "failed: autotrash reported" "$F" 'node_systemd_user_unit_failed{user="fred",name="autotrash.service"} 1'
has "failed: backslash in unit name escaped" "$F" 'node_systemd_user_unit_failed{user="fred",name="mnt-nas\\x2dmedia.mount"} 1'
has "failed: count per user" "$F" 'node_systemd_user_units_failed{user="fred"} 2'
has "failed: other user counted separately" "$F" 'node_systemd_user_units_failed{user="nik"} 0'
lacks "failed: nothing attributed to the wrong user" "$F" 'user="nik",name='

# ---------------------------------------------------------------------------
# A manager that does not answer: unknown, not zero
# ---------------------------------------------------------------------------

reset
echo '[{"uid":1000,"user":"fred","linger":true,"state":"active"},{"uid":1001,"user":"nik","linger":false,"state":"closing"}]' >"$FAKE/users"
echo '[]' >"$FAKE/units.fred"
F="$(run manager-down)"
valid "manager down" "$F"
has "manager down: reported as down" "$F" 'node_systemd_user_manager_up{user="nik"} 0'
lacks "manager down: no count claimed for it" "$F" '^node_systemd_user_units_failed\{user="nik"\}'
has "manager down: other users unaffected" "$F" 'node_systemd_user_units_failed{user="fred"} 0'
has "manager down: collector itself still ok" "$F" 'node_systemd_user_units_collector_ok 1'

# Garbage from systemctl is treated the same as no answer.
reset
echo '[{"uid":1000,"user":"fred","linger":true,"state":"active"}]' >"$FAKE/users"
echo 'Failed to connect to bus' >"$FAKE/units.fred"
F="$(run manager-garbage)"
valid "manager garbage" "$F"
has "manager garbage: reported as down" "$F" 'node_systemd_user_manager_up{user="fred"} 0'

# ---------------------------------------------------------------------------
# loginctl fails: the file is still written, and says so
# ---------------------------------------------------------------------------

reset
F="$(run loginctl-down)"
valid "loginctl down" "$F"
has "loginctl down: collector not ok" "$F" 'node_systemd_user_units_collector_ok 0'
lacks "loginctl down: no per-user series" "$F" 'user="'

reset
echo 'not json' >"$FAKE/users"
F="$(run loginctl-garbage)"
valid "loginctl garbage" "$F"
has "loginctl garbage: collector not ok" "$F" 'node_systemd_user_units_collector_ok 0'

# No users at all (nobody logged in, no linger) is fine, not a failure.
reset
echo '[]' >"$FAKE/users"
F="$(run no-users)"
valid "no users" "$F"
has "no users: collector ok" "$F" 'node_systemd_user_units_collector_ok 1'

# ---------------------------------------------------------------------------
# Escaping and atomicity
# ---------------------------------------------------------------------------

reset
printf '%s\n' '[{"uid":1000,"user":"fred","linger":true,"state":"active"}]' >"$FAKE/users"
printf '%s\n' '[{"unit":"we\"ird\\\\name.service","load":"loaded","active":"failed","sub":"failed","description":""}]' >"$FAKE/units.fred"
F="$(run escaping)"
valid "escaping" "$F"
has "escaping: quote and backslash escaped" "$F" 'node_systemd_user_unit_failed{user="fred",name="we\"ird\\\\name.service"} 1'
if [[ -z "$(find "$WORK/out" -name 'systemd_user_units.prom.*')" ]]; then ok; else bad "no temp files left behind"; fi

# A previous file is replaced, never appended to.
reset
echo '[{"uid":1000,"user":"fred","linger":true,"state":"active"}]' >"$FAKE/users"
echo '[]' >"$FAKE/units.fred"
F="$(run escaping)"
lacks "rerun: stale failure cleared" "$F" 'weird|we\\"ird'

# ---------------------------------------------------------------------------

printf 'systemd-user-units: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
