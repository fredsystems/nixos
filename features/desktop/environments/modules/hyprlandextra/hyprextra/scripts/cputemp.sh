#!/usr/bin/env bash

set -euo pipefail

temps=()

for hw in /sys/class/hwmon/hwmon*; do
    [[ -r "$hw/name" ]] || continue

    [[ $(cat "$hw/name") == "k10temp" ]] || continue
    # We prefer tctl over tccd
    # But some systems may not have tctl
    tctl_temps=()
    tccd_temps=()
    for label in "$hw"/temp*_label; do
        [[ -r "$label" ]] || continue
        if [[ $(cat "$label") == Tctl* ]]; then
            input="${label/_label/_input}"
            tctl_temps+=("$(cat "$input")")
        elif [[ $(cat "$label") == Tccd* ]]; then
            input="${label/_label/_input}"
            tccd_temps+=("$(cat "$input")")
        fi
    done
    if ((${#tctl_temps[@]} > 0)); then
        temps+=("${tctl_temps[@]}")
    elif ((${#tccd_temps[@]} > 0)); then
        temps+=("${tccd_temps[@]}")
    fi
done

if ((${#temps[@]} == 0)); then
    echo '{"text":" ?","class":"unknown"}'
    exit 0
fi

temp_millic=$(printf '%s\n' "${temps[@]}" | sort -nr | head -n1)
temp=$(awk "BEGIN { printf \"%.0f\", $temp_millic / 1000 }")

class="normal"
icon=""

if ((temp >= 85)); then
    class="critical"
    icon="❗"
elif ((temp >= 70)); then
    class="warning"
    icon="⚠️"
fi

jq -nc \
    --arg text "$icon ${temp}°C" \
    --arg class "$class" \
    '{text:$text, class:$class}'
