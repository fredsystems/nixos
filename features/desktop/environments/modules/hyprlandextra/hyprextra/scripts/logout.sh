#!/usr/bin/env bash

if [[ "$XDG_CURRENT_DESKTOP" == "Hyprland" ]]; then
    hyprctl dispatch exit
elif [[ "$XDG_CURRENT_DESKTOP" == "niri" ]]; then
    niri msg action quit
fi
