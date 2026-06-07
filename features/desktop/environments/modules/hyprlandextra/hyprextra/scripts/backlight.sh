#!/usr/bin/env bash

SCALE="$1"

# if scale is unset, return an error
if [[ -z "$SCALE" ]]; then
	echo "Error: scale is not set"
	exit 1
fi

# Brightness changes are surfaced by wayle's built-in transient OSD, which
# observes the backlight state directly, so this script only performs the
# change (no notify-send). SCALE is retained so per-host callers can pass the
# DDC bus id / scaling factor used by `get_backlight`.

# Get brightness
get_backlight() {
	LIGHT=$(printf "%.0f\n" "$(brightnessctl g)")

	# we may need to scale the value on some systems
	# if the value is < 255 then we need to scale it
	# 255 should become 100000
	if [[ "$LIGHT" != 0 ]]; then
		LIGHT=$((LIGHT * 100 / SCALE))
	fi
	echo "${LIGHT}"
}

# Increase brightness
inc_backlight() {
	brightnessctl s +5%
}

# Decrease brightness
dec_backlight() {
	brightnessctl s 5%-
}

# Execute accordingly
if [[ "$2" == "--get" ]]; then
	get_backlight
elif [[ "$2" == "--inc" ]]; then
	inc_backlight
elif [[ "$2" == "--dec" ]]; then
	dec_backlight
else
	get_backlight
fi
