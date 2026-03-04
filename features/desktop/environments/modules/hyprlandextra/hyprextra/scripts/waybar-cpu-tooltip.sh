#!/usr/bin/env bash
set -euo pipefail

NUM_CORES=$(grep -c '^cpu[0-9]' /proc/stat)

# --- sample /proc/stat twice ---
readarray -t PREV </proc/stat
sleep 0.1
readarray -t CURR </proc/stat

cpu_usage() {
    local -a p c
    read -r -a p <<<"$1"
    read -r -a c <<<"$2"

    local prev_idle=${p[4]}
    local idle=${c[4]}

    local prev_total=0
    local total=0
    for i in {1..8}; do
        prev_total=$((prev_total + p[i]))
        total=$((total + c[i]))
    done

    local diff_idle=$((idle - prev_idle))
    local diff_total=$((total - prev_total))

    awk "BEGIN { printf \"%.1f\", (1 - $diff_idle / $diff_total) * 100 }"
}

cpu_bar() {
    local usage=$1
    local bars=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)

    (($(awk "BEGIN {print ($usage < 0)}"))) && usage=0
    (($(awk "BEGIN {print ($usage > 100)}"))) && usage=100

    local idx
    idx=$(awk "BEGIN { printf \"%d\", ($usage / 100) * 7 }")

    local bar="${bars[$idx]}"
    local color

    if (($(awk "BEGIN {print ($usage < 20)}"))); then
        color="#7f849c"
    elif (($(awk "BEGIN {print ($usage < 50)}"))); then
        color="#a6e3a1"
    elif (($(awk "BEGIN {print ($usage < 80)}"))); then
        color="#f9e2af"
    else
        color="#f38ba8"
    fi

    echo "<span foreground=\"$color\">$bar</span>"
}

# --- total CPU ---
read -r -a TOTAL_PREV <<<"${PREV[0]}"
read -r -a TOTAL_CURR <<<"${CURR[0]}"

CPU_TOTAL=$(cpu_usage "${TOTAL_PREV[*]}" "${TOTAL_CURR[*]}")

# -------------------------------------------------------------------
# Build CPU topology map: (package,core) -> logical CPUs
# -------------------------------------------------------------------

declare -A CORE_MAP
declare -A CORE_USAGE

for i in "${!PREV[@]}"; do
    [[ ${PREV[$i]} =~ ^cpu[0-9]+ ]] || continue

    cpu=${PREV[$i]%% *}
    cpu_id=${cpu#cpu}

    topo="/sys/devices/system/cpu/cpu${cpu_id}/topology"
    [[ -r "$topo/core_id" ]] || continue

    core_id=$(<"$topo/core_id")
    pkg_id=$(<"$topo/physical_package_id")

    key="${pkg_id}:${core_id}"

    read -r -a CORE_PREV <<<"${PREV[$i]}"
    read -r -a CORE_CURR <<<"${CURR[$i]}"

    USAGE=$(cpu_usage "${CORE_PREV[*]}" "${CORE_CURR[*]}")

    CORE_MAP["$key"]+="${cpu_id} "
    CORE_USAGE["$cpu_id"]="$USAGE"
done

# -------------------------------------------------------------------
# Build paired core display rows
# -------------------------------------------------------------------

# --- sort physical cores by package:core_id ---
mapfile -t SORTED_CORE_KEYS < <(
    for key in "${!CORE_MAP[@]}"; do
        echo "$key"
    done | sort -t: -k1,1n -k2,2n
)

PAIRED_CORES=()

for key in "${SORTED_CORE_KEYS[@]}"; do
    read -r -a siblings <<<"${CORE_MAP[$key]}"

    label=$(printf "C%02d" "${key##*:}")

    if ((${#siblings[@]} == 1)); then
        u=${CORE_USAGE[${siblings[0]}]}
        b=$(cpu_bar "$u")
        row="$label $b $(printf "%5.1f%%" "$u")"
    else
        u1=${CORE_USAGE[${siblings[0]}]}
        u2=${CORE_USAGE[${siblings[1]}]}
        b1=$(cpu_bar "$u1")
        b2=$(cpu_bar "$u2")
        row="$label $b1$b2 $(printf "%5.1f%% %5.1f%%" "$u1" "$u2")"
    fi

    PAIRED_CORES+=("$row")
done

CORE_COUNT=${#PAIRED_CORES[@]}

# --- decide grid width ---
if ((CORE_COUNT <= 4)); then
    COLS=1
elif ((CORE_COUNT <= 8)); then
    COLS=2
elif ((CORE_COUNT <= 16)); then
    COLS=3
else
    COLS=4
fi

# --- column-major grid build ---
ROWS=$(((CORE_COUNT + COLS - 1) / COLS))

CORE_GRID=""
for ((r = 0; r < ROWS; r++)); do
    for ((c = 0; c < COLS; c++)); do
        idx=$((c * ROWS + r))
        ((idx >= CORE_COUNT)) && continue

        CORE_GRID+=$(printf "%-22s" "${PAIRED_CORES[$idx]}")
        ((c < COLS - 1)) && CORE_GRID+=" "
    done
    CORE_GRID+=$'\n'
done

# -------------------------------------------------------------------
# Top processes (unchanged)
# -------------------------------------------------------------------

INTERVAL=0.3
CLK_TCK=$(getconf CLK_TCK)

declare -A CPU1 CPU2 COMM

for stat in /proc/[0-9]*/stat; do
    [[ -r $stat ]] || continue
    pid=${stat#/proc/}
    pid=${pid%/stat}
    if read -r _ _ _ _ _ _ _ _ _ _ _ utime stime _ <"$stat"; then
        CPU1[$pid]=$((utime + stime))
        [[ -r /proc/$pid/comm ]] && COMM[$pid]=$(</proc/"$pid"/comm)
    fi
done

sleep "$INTERVAL"

for stat in /proc/[0-9]*/stat; do
    [[ -r $stat ]] || continue
    pid=${stat#/proc/}
    pid=${pid%/stat}
    [[ -n ${CPU1[$pid]:-} ]] || continue
    if read -r _ _ _ _ _ _ _ _ _ _ _ utime stime _ <"$stat"; then
        CPU2[$pid]=$((utime + stime))
    fi
done

TOP_PROCS=$(
    {
        for pid in "${!CPU2[@]}"; do
            delta=$((CPU2[$pid] - CPU1[$pid]))
            cpu=$(awk -v d="$delta" -v t="$INTERVAL" -v c="$CLK_TCK" -v n="$NUM_CORES" \
                'BEGIN { printf "%.1f", (d / c) / t / n * 100 }')
            BAR=$(cpu_bar "$cpu")
            printf "%s %5.1f%%  %-18s\n" "$BAR" "$cpu" "${COMM[$pid]:-unknown}"
        done
    } | sort -nr | sed -n '1,5p'
)

# --- tooltip text ---
TOOLTIP=$(
    cat <<EOF
  CPU: ${CPU_TOTAL}%

Cores:
${CORE_GRID}

Top Processes:
${TOP_PROCS}
EOF
)

# --- emit JSON ---
jq -nc \
    --arg text " ${CPU_TOTAL}%" \
    --arg tooltip "<span font_family=\"monospace\">$TOOLTIP</span>" \
    '{text: $text, tooltip: $tooltip, class: "cpu"}'
