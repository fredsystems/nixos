#!/usr/bin/env bash

iDIR="$HOME/.config/hyprextra/icons"

# Get Volume
get_volume() {
    pamixer --get-volume
}

get_volume_bar() {
    mute_state=$(pamixer --get-mute)
    if [[ "$mute_state" == "true" ]]; then
        echo "Muted"
    else
        get_volume
    fi
}

get_icon_bar() {
    mute_state=$(pamixer --get-mute)
    if [[ "$mute_state" == "true" ]]; then
        echo "$iDIR/volume-mute.png"
    else
        get_icon
    fi
}

# Get icons
get_icon() {
    current=$(get_volume)
    if [[ "$current" -eq "0" ]]; then
        echo "$iDIR/volume-mute.png"
    elif [[ ("$current" -ge "0") && ("$current" -le "30") ]]; then
        echo "$iDIR/volume-low.png"
    elif [[ ("$current" -ge "30") && ("$current" -le "60") ]]; then
        echo "$iDIR/volume-mid.png"
    elif [[ ("$current" -ge "60") && ("$current" -le "100") ]]; then
        echo "$iDIR/volume-high.png"
    fi
}

# Notify
notify_user() {
    notify-send -h string:x-canonical-private-synchronous:sys-notify -u low -i "$(get_icon)" "Volume : $(get_volume) %"
}

# Increase Volume
inc_volume() {
    prev=$(get_volume)

    # normalize the volume change. Make it so that whatever we change the volume by results in a final volume % 5 == 0

    adjustment=5
    remainder=$((prev % 5))
    if [[ $remainder -ne 0 ]]; then
        adjustment=$((5 - remainder))
    fi

    pamixer -i $adjustment

    # if the new volume is 0, run toggle mute
    if [ "$prev" -eq 0 ]; then
        mute_state=$(pamixer --get-mute)
        if [[ "$mute_state" == "true" ]]; then
            toggle_mute
        fi
    elif [ "$prev" -ne 100 ]; then
        unmute_if_muted
        notify_user
    elif [ "$prev" -eq 100 ]; then
        unmute_if_muted
    fi
}

# Decrease Volume
dec_volume() {
    prev=$(get_volume)

    # normalize the volume change. Make it so that whatever we change the volume by results in a final volume % 5 == 0

    adjustment=5
    remainder=$((prev % 5))
    if [[ $remainder -ne 0 ]]; then
        adjustment=$remainder
    fi

    pamixer -d $adjustment
    new=$(get_volume)

    # if the current volume is 0, run toggle mute
    if [[ "$new" -eq 0 && "$prev" -ne 0 ]]; then
        mute_state=$(pamixer --get-mute)
        if [[ "$mute_state" == "false" ]]; then
            toggle_mute
        fi
    elif [[ "$prev" -ne 0 ]]; then
        unmute_if_muted
        notify_user
    elif [[ "$prev" -eq 0 ]]; then
        mute_if_unmuted
    fi
}

# Toggle Mute
toggle_mute() {
    if [ "$(pamixer --get-mute)" == "false" ]; then
        pamixer -m && notify-send -h string:x-canonical-private-synchronous:sys-notify -u low -i "$iDIR/volume-mute.png" "Volume Switched OFF"
        if [[ -d "/sys/class/leds/platform::mute" ]]; then
            brightnessctl --device="platform::mute" set 1
        fi
    elif [ "$(pamixer --get-mute)" == "true" ]; then
        pamixer -u && notify-send -h string:x-canonical-private-synchronous:sys-notify -u low -i "$(get_icon)" "Volume Switched ON"
        if [[ -d "/sys/class/leds/platform::mute" ]]; then
            brightnessctl --device="platform::mute" set 0
        fi
    fi
}

unmute_if_muted() {
    if [ "$(pamixer --get-mute)" == "true" ]; then
        pamixer -u
        if [[ -d "/sys/class/leds/platform::mute" ]]; then
            brightnessctl --device="platform::mute" set 0
        fi
    fi
}

mute_if_unmuted() {
    if [ "$(pamixer --get-mute)" == "false" ]; then
        pamixer -m
        if [[ -d "/sys/class/leds/platform::mute" ]]; then
            brightnessctl --device="platform::mute" set 1
        fi
    fi
}

# Toggle Mic
toggle_mic() {
    if [ "$(pamixer --default-source --get-mute)" == "false" ]; then
        pamixer --default-source -m && notify-send -h string:x-canonical-private-synchronous:sys-notify -u low -i "$iDIR/microphone-mute.png" "Microphone Switched OFF"
        if [[ -d "/sys/class/leds/platform::micmute" ]]; then
            brightnessctl --device="platform::micmute" set 1
        fi
    elif [ "$(pamixer --default-source --get-mute)" == "true" ]; then
        pamixer -u --default-source u && notify-send -h string:x-canonical-private-synchronous:sys-notify -u low -i "$iDIR/microphone.png" "Microphone Switched ON"
        if [[ -d "/sys/class/leds/platform::micmute" ]]; then
            brightnessctl --device="platform::micmute" set 0
        fi
    fi
}
# Get icons
get_mic_icon() {
    current=$(pamixer --default-source --get-volume)
    if [[ "$current" -eq "0" ]]; then
        echo "$iDIR/microphone.png"
    elif [[ ("$current" -ge "0") && ("$current" -le "30") ]]; then
        echo "$iDIR/microphone.png"
    elif [[ ("$current" -ge "30") && ("$current" -le "60") ]]; then
        echo "$iDIR/microphone.png"
    elif [[ ("$current" -ge "60") && ("$current" -le "100") ]]; then
        echo "$iDIR/microphone.png"
    fi
}
# Notify
notify_mic_user() {
    notify-send -h string:x-canonical-private-synchronous:sys-notify -u low -i "$(get_mic_icon)" "Mic-Level : $(pamixer --default-source --get-volume) %"
}

# Increase MIC Volume
inc_mic_volume() {
    pamixer --default-source -i 5 && notify_mic_user
}

# Decrease MIC Volume
dec_mic_volume() {
    pamixer --default-source -d 5 && notify_mic_user
}

get_sink_name() {
    local sink
    sink="$(pactl get-default-sink)"

    pactl list sinks | awk -v s="$sink" '
    $1 == "Name:" { name = $2 }
    $1 == "Description:" && name == s {
      gsub(/^[[:space:]]+/, "", $0)
      sub(/^Description:[[:space:]]*/, "", $0)
      print
      exit
    }
  ' | sed -E \
        -e 's/^Family .* HD Audio Controller/Built-in Audio/i' \
        -e 's/Speaker(s)?$/Speakers/i'
}

# Execute accordingly
if [[ "$1" == "--get" ]]; then
    get_volume
elif [[ "$1" == "--inc" ]]; then
    inc_volume
elif [[ "$1" == "--dec" ]]; then
    dec_volume
elif [[ "$1" == "--toggle" ]]; then
    toggle_mute
elif [[ "$1" == "--toggle-mic" ]]; then
    toggle_mic
elif [[ "$1" == "--get-icon" ]]; then
    get_icon
elif [[ "$1" == "--get-mic-icon" ]]; then
    get_mic_icon
elif [[ "$1" == "--mic-inc" ]]; then
    inc_mic_volume
elif [[ "$1" == "--mic-dec" ]]; then
    dec_mic_volume
elif [[ "$1" == "--get-bar" ]]; then
    get_volume_bar
elif [[ "$1" == "--get-icon-bar" ]]; then
    get_icon_bar
elif [[ "$1" == "--get-sink-name" ]]; then
    get_sink_name
else
    get_volume
fi
