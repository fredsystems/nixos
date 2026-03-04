#!/usr/bin/env bash

last=""

while true; do
    current=$(wpctl get-volume @DEFAULT_AUDIO_SINK@)

    if [[ "$current" != "$last" ]]; then
        if grep -q '\[MUTED\]' <<< "$current"; then
            brightnessctl --device="platform::mute" set 1
        else
            brightnessctl --device="platform::mute" set 0
        fi

        last="$current"
    fi

    sleep 0.3   # 300ms, adjust as desired
done
