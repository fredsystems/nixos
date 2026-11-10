# shellcheck shell=bash
#
# home-ip.sh -- pure helpers for scripts/rotate-home-ip.sh.
#
# Sourced, not executed. Everything here is strings in, strings out: no
# network, no git, no Nix. That split is what lets
# scripts/tests/home-ip-test.sh exercise every rule with fixtures, and the
# rules here are the ones that decide what lands in fredvps's fail2ban
# ignoreIP list -- a wrong answer is either a self-lockout or a stranger
# whitelisted on the internet-facing host.

# Strict dotted-quad with range-checked octets. Same pattern as the
# strMatching type on shared.homePublicIPv4, so anything this accepts the
# module accepts too, and a typo is refused here rather than at eval time.
HIP_OCTET_RE='(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
HIP_IPV4_RE="^${HIP_OCTET_RE}(\\.${HIP_OCTET_RE}){3}\$"

# hip_is_ipv4 <string> -- 0 if a valid IPv4 address.
hip_is_ipv4() {
    [[ "$1" =~ $HIP_IPV4_RE ]]
}

# hip_ip_to_int <ipv4> -- the address as an unsigned 32-bit integer.
hip_ip_to_int() {
    local a b c d
    IFS=. read -r a b c d <<<"$1"
    printf '%s\n' "$(((a << 24) | (b << 16) | (c << 8) | d))"
}

# hip_in_cidr <ipv4> <a.b.c.d/len> -- 0 if the address is inside the block.
hip_in_cidr() {
    local ip="$1" net="${2%/*}" len="${2#*/}" mask
    hip_is_ipv4 "$ip" || return 1
    hip_is_ipv4 "$net" || return 1
    [[ "$len" =~ ^([0-9]|[12][0-9]|3[0-2])$ ]] || return 1
    if [[ "$len" -eq 0 ]]; then
        mask=0
    else
        mask=$(((0xFFFFFFFF << (32 - len)) & 0xFFFFFFFF))
    fi
    [[ $(($(hip_ip_to_int "$ip") & mask)) -eq $(($(hip_ip_to_int "$net") & mask)) ]]
}

# hip_parse_observed -- reads sdrhub's home_public_ip.prom on stdin and prints
# the `observed` label of home_public_ip_matches_expected. Prints nothing and
# returns 1 when the series is absent (the generator omits it when its lookup
# failed) or the label is not a valid address.
hip_parse_observed() {
    local observed
    observed="$(sed -n 's/^home_public_ip_matches_expected{.*observed="\([^"]*\)".*}.*$/\1/p' | head -n 1)"
    hip_is_ipv4 "$observed" || return 1
    printf '%s\n' "$observed"
}

# hip_consensus <addr>... -- prints the single address every argument agrees
# on. Empty arguments (a source that did not answer) are skipped; returns 1
# when nothing answered or any two answers differ.
hip_consensus() {
    local v agreed=""
    for v in "$@"; do
        [[ -n "$v" ]] || continue
        hip_is_ipv4 "$v" || return 1
        if [[ -z "$agreed" ]]; then
            agreed="$v"
        elif [[ "$v" != "$agreed" ]]; then
            return 1
        fi
    done
    [[ -n "$agreed" ]] || return 1
    printf '%s\n' "$agreed"
}

# The one line in modules/data/home-network.nix holding the address. Matched
# by shape rather than by option name because `default = ` sits on its own
# line inside the mkOption; the "exactly one match" rule below is what makes
# that safe if the file ever grows a second option.
HIP_DEFAULT_RE='^([[:space:]]*default = ")([0-9.]+)(";[[:space:]]*)$'

# hip_current_value -- reads home-network.nix on stdin and prints the
# configured address. Returns 1 unless there is exactly one candidate line and
# it holds a valid address.
hip_current_value() {
    local line value="" count=0
    while IFS= read -r line; do
        if [[ "$line" =~ $HIP_DEFAULT_RE ]]; then
            count=$((count + 1))
            value="${BASH_REMATCH[2]}"
        fi
    done
    [[ "$count" -eq 1 ]] || return 1
    hip_is_ipv4 "$value" || return 1
    printf '%s\n' "$value"
}

# hip_replace_value <old> <new> -- rewrites home-network.nix from stdin to
# stdout with the address changed. Refuses (returns 1, prints nothing useful)
# unless the file currently holds exactly <old>, so a stale <old> cannot
# silently produce an unchanged file or rewrite the wrong line.
hip_replace_value() {
    local old="$1" new="$2" input current line
    hip_is_ipv4 "$new" || return 1
    input="$(cat)"
    current="$(hip_current_value <<<"$input")" || return 1
    [[ "$current" == "$old" ]] || return 1
    while IFS= read -r line; do
        if [[ "$line" =~ $HIP_DEFAULT_RE ]]; then
            printf '%s%s%s\n' "${BASH_REMATCH[1]}" "$new" "${BASH_REMATCH[3]}"
        else
            printf '%s\n' "$line"
        fi
    done <<<"$input"
}

# hip_branch_name <ipv4> -- fix/home-ip-168-93-60-127
hip_branch_name() {
    printf 'fix/home-ip-%s\n' "${1//./-}"
}

# hip_ignoreip_has <ipv4> -- reads `fail2ban-client get <jail> ignoreip`
# output on stdin; 0 if the address is listed as an exact entry.
hip_ignoreip_has() {
    local ip="$1" line
    while IFS= read -r line; do
        line="${line#*- }"
        line="${line%"${line##*[![:space:]]}"}"
        [[ "$line" == "$ip" ]] && return 0
    done
    return 1
}
