#!/usr/bin/env bash

DIR="$HOME/Pictures/Background/"
INTERVAL=300 # seconds

ls -l "$DIR"

while true; do
    echo "Starting background script"
    find "$DIR" -type f | shuf | while read -r img; do
        echo "Setting background to $img"
        swaybg -o "*" -i "$img" -m fill &
        PID=$!
        sleep "$INTERVAL"
        kill "$PID"
    done
    echo "Background script finished"
done
