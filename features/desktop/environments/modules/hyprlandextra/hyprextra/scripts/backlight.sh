#!/usr/bin/env bash

SCALE="$1"

# if scale is unset, return an error
if [[ -z "$SCALE" ]]; then
	echo "Error: scale is not set"
	exit 1
fi

# wayle's and Noctalia's OSDs both observe the backlight directly, but
# Noctalia only reacts to an actual change, so at 0% or 100% a key press would
# show nothing. show_osd tells Noctalia the current level explicitly; it is a
# no-op where Noctalia is not installed. SCALE is retained so per-host callers
# can pass the DDC bus id / scaling factor used by `get_backlight`.

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

show_osd() {
	if command -v noctalia >/dev/null 2>&1; then
		noctalia msg brightness-osd "$(brightnessctl -m | cut -d, -f4)" >/dev/null 2>&1 || true
	fi
}

# Increase brightness
inc_backlight() {
	brightnessctl s +5%
	show_osd
}

# Decrease brightness
dec_backlight() {
	brightnessctl s 5%-
	show_osd
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
