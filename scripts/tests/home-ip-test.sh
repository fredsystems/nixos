#!/usr/bin/env bash
#
# home-ip-test.sh -- hermetic tests for scripts/lib/home-ip.sh, the helpers
# scripts/rotate-home-ip.sh uses to decide what goes into fredvps's fail2ban
# ignoreIP list.
#
# Also runs hip_current_value against the real modules/data/home-network.nix,
# so a reshaped option that the rotation script could no longer edit fails
# here rather than on the day the address rotates.
#
# No network, no root, no Nix daemon: runs as a flake check
# (`.#checks.<system>.home-ip`) and as a pre-commit hook.
#
# Usage: bash scripts/tests/home-ip-test.sh   (from the repo root)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/home-ip.sh
source "$ROOT/scripts/lib/home-ip.sh"

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); }
bad() {
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n' "$1" >&2
    [[ $# -lt 2 ]] || printf '      %s\n' "${@:2}" >&2
}
eq() { # name expected actual
    if [[ "$2" == "$3" ]]; then ok; else bad "$1" "expected: $2" "actual:   $3"; fi
}
yes_() { # name cmd...
    local name="$1"
    shift
    if "$@"; then ok; else bad "$name" "expected success: $*"; fi
}
no_() { # name cmd...
    local name="$1"
    shift
    if "$@"; then bad "$name" "expected failure: $*"; else ok; fi
}

# ---------------------------------------------------------------------------
# hip_is_ipv4
# ---------------------------------------------------------------------------

yes_ "ipv4: plain" hip_is_ipv4 168.93.60.127
yes_ "ipv4: zeros" hip_is_ipv4 0.0.0.0
yes_ "ipv4: max" hip_is_ipv4 255.255.255.255
no_ "ipv4: octet 256" hip_is_ipv4 168.93.60.256
no_ "ipv4: fat-fingered 999" hip_is_ipv4 999.26.160.99
no_ "ipv4: leading zero" hip_is_ipv4 168.093.60.127
no_ "ipv4: three octets" hip_is_ipv4 168.93.60
no_ "ipv4: five octets" hip_is_ipv4 168.93.60.127.1
no_ "ipv4: cidr" hip_is_ipv4 168.93.0.0/18
no_ "ipv4: empty" hip_is_ipv4 ""
no_ "ipv4: trailing newline" hip_is_ipv4 $'168.93.60.127\n'
no_ "ipv4: html" hip_is_ipv4 "<html>"
no_ "ipv4: v6" hip_is_ipv4 "::1"

# ---------------------------------------------------------------------------
# hip_in_cidr
# ---------------------------------------------------------------------------

yes_ "cidr: inside" hip_in_cidr 168.93.60.127 168.93.0.0/18
yes_ "cidr: network address" hip_in_cidr 168.93.0.0 168.93.0.0/18
yes_ "cidr: last address" hip_in_cidr 168.93.63.255 168.93.0.0/18
no_ "cidr: one past the end" hip_in_cidr 168.93.64.0 168.93.0.0/18
no_ "cidr: one before" hip_in_cidr 168.92.255.255 168.93.0.0/18
no_ "cidr: old ISP" hip_in_cidr 73.26.160.99 168.93.0.0/18
yes_ "cidr: /32 exact" hip_in_cidr 10.0.0.1 10.0.0.1/32
no_ "cidr: /32 other" hip_in_cidr 10.0.0.2 10.0.0.1/32
yes_ "cidr: /0 anything" hip_in_cidr 1.2.3.4 0.0.0.0/0
no_ "cidr: bad length" hip_in_cidr 1.2.3.4 0.0.0.0/33
no_ "cidr: bad address" hip_in_cidr 1.2.3.999 1.2.3.0/24

# ---------------------------------------------------------------------------
# hip_parse_observed
# ---------------------------------------------------------------------------

PROM_DRIFTED='# HELP home_public_ip_check_up Whether the observed home public IP could be determined.
# TYPE home_public_ip_check_up gauge
home_public_ip_check_up 1
# HELP home_public_ip_matches_expected Whether the address fredvps observes matches the configured one.
# TYPE home_public_ip_matches_expected gauge
home_public_ip_matches_expected{observed="168.93.60.127",expected="168.93.61.33"} 0
# HELP home_public_ip_check_timestamp_seconds Unix time this file was last written.
# TYPE home_public_ip_check_timestamp_seconds gauge
home_public_ip_check_timestamp_seconds 1794325590'

PROM_FAILED='home_public_ip_check_up 0
home_public_ip_check_timestamp_seconds 1794325590'

eq "parse: drifted file" "168.93.60.127" "$(hip_parse_observed <<<"$PROM_DRIFTED")"
no_ "parse: failed lookup has no series" hip_parse_observed <<<"$PROM_FAILED"
no_ "parse: empty input" hip_parse_observed </dev/null
no_ "parse: garbage label" hip_parse_observed <<<'home_public_ip_matches_expected{observed="nope",expected="1.2.3.4"} 0'

# ---------------------------------------------------------------------------
# hip_consensus
# ---------------------------------------------------------------------------

eq "consensus: one" "1.2.3.4" "$(hip_consensus 1.2.3.4)"
eq "consensus: agree" "1.2.3.4" "$(hip_consensus 1.2.3.4 1.2.3.4)"
eq "consensus: silent source skipped" "1.2.3.4" "$(hip_consensus "" 1.2.3.4)"
no_ "consensus: disagree" hip_consensus 1.2.3.4 1.2.3.5
no_ "consensus: nobody answered" hip_consensus "" ""
no_ "consensus: no arguments" hip_consensus
no_ "consensus: junk answer" hip_consensus 1.2.3.4 "<html>"

# ---------------------------------------------------------------------------
# hip_current_value / hip_replace_value
# ---------------------------------------------------------------------------

NIX_FIXTURE='{ lib, ... }:
{
  options.shared.homePublicIPv4 = lib.mkOption {
    type = lib.types.str;
    default = "168.93.61.33";
    description = '"''"'
      Mentions default = "1.2.3.4" in prose, indented differently.
    '"''"';
  };
}'

eq "current: fixture" "168.93.61.33" "$(hip_current_value <<<"$NIX_FIXTURE")"
no_ "current: no default line" hip_current_value <<<'{ }'
no_ "current: two default lines" hip_current_value <<<'    default = "1.2.3.4";
    default = "1.2.3.5";'
no_ "current: invalid address" hip_current_value <<<'    default = "999.1.1.1";'

REPLACED="$(hip_replace_value 168.93.61.33 168.93.60.127 <<<"$NIX_FIXTURE")"
eq "replace: new value read back" "168.93.60.127" "$(hip_current_value <<<"$REPLACED")"
eq "replace: only that line changed" \
    "${NIX_FIXTURE/\"168.93.61.33\"/\"168.93.60.127\"}" "$REPLACED"
no_ "replace: stale old value refused" hip_replace_value 1.1.1.1 168.93.60.127 <<<"$NIX_FIXTURE"
no_ "replace: invalid new value refused" hip_replace_value 168.93.61.33 168.93.60.999 <<<"$NIX_FIXTURE"

# The real file must stay editable by the rotation script.
REAL="$ROOT/modules/data/home-network.nix"
if real_value="$(hip_current_value <"$REAL")"; then
    ok
    eq "real file: replace round-trips" "$(cat "$REAL")" \
        "$(hip_replace_value 10.0.0.1 "$real_value" <<<"$(hip_replace_value "$real_value" 10.0.0.1 <"$REAL")")"
else
    bad "real file: $REAL must hold exactly one 'default = \"<ipv4>\";' line"
fi

# ---------------------------------------------------------------------------
# hip_branch_name / hip_ignoreip_has
# ---------------------------------------------------------------------------

eq "branch name" "fix/home-ip-168-93-60-127" "$(hip_branch_name 168.93.60.127)"

IGNOREIP='These IP addresses/networks are ignored:
|- 127.0.0.0/8
|- 100.64.0.0/10
|- 168.93.60.127
|- 209.40.70.5
`- ::1'

yes_ "ignoreip: listed" hip_ignoreip_has 168.93.60.127 <<<"$IGNOREIP"
yes_ "ignoreip: last entry" hip_ignoreip_has ::1 <<<"$IGNOREIP"
no_ "ignoreip: absent" hip_ignoreip_has 168.93.61.33 <<<"$IGNOREIP"
no_ "ignoreip: prefix is not a match" hip_ignoreip_has 168.93.60.12 <<<"$IGNOREIP"
no_ "ignoreip: empty output" hip_ignoreip_has 168.93.60.127 </dev/null

# ---------------------------------------------------------------------------

printf 'home-ip: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
