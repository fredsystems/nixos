#!/usr/bin/env bash

# shellcheck disable=SC2035

# Brightness changes are surfaced by wayle's built-in transient OSD, which
# observes the backlight sysfs node directly, so this script only performs
# the change (no notify-send).

# Get brightness
get_backlight() {
    LIGHT="$(cat /sys/class/leds/*::kbd_backlight/brightness)"
    echo "${LIGHT}"
}

# Increase brightness
inc_backlight() {
    brightnessctl -d *::kbd_backlight set 33%+
}

# Decrease brightness
dec_backlight() {
    brightnessctl -d *::kbd_backlight set 33%-
}

# Zero brightness
zero_backlight() {
    brightnessctl -d *::kbd_backlight s 0%
}

# Full brightness
full_backlight() {
    brightnessctl -d *::kbd_backlight s 100%
}

# Execute accordingly
if [[ "$1" == "--get" ]]; then
    brightnessctl -d '*::kbd_backlight' g
elif [[ "$1" == "--inc" ]]; then
    inc_backlight
elif [[ "$1" == "--dec" ]]; then
    dec_backlight
elif [[ "$1" == "--zero" ]]; then
    zero_backlight
elif [[ "$1" == "--full" ]]; then
    full_backlight

else
    get_backlight
fi
