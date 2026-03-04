#!/usr/bin/env bash

iDIR="$HOME/.config/hyprextra/icons"
SCALE="$1"

# if scale is unset, return an error
if [[ -z "$SCALE" ]]; then
	echo "Error: scale is not set"
	exit 1
fi

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

# Get icons
get_icon() {
	current="$(get_backlight)"
	if [[ ("$current" -ge "0") && ("$current" -le "19") ]]; then
		icon="$iDIR/brightness-20.png"
	elif [[ ("$current" -ge "19") && ("$current" -le "39") ]]; then
		icon="$iDIR/brightness-40.png"
	elif [[ ("$current" -ge "39") && ("$current" -le "59") ]]; then
		icon="$iDIR/brightness-60.png"
	elif [[ ("$current" -ge "59") && ("$current" -le "79") ]]; then
		icon="$iDIR/brightness-80.png"
	elif [[ ("$current" -ge "79") ]]; then
		icon="$iDIR/brightness-100.png"
	fi
}

# Notify
notify_user() {
	notify-send -h string:x-canonical-private-synchronous:sys-notify -u low -i "$icon" "Brightness : $(get_backlight)%"
}

# Increase brightness
inc_backlight() {
	brightnessctl s +5% && get_icon && notify_user
}

# Decrease brightness
dec_backlight() {
	brightnessctl s 5%- && get_icon && notify_user
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
