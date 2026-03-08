#!/usr/bin/env bash
# dpms.sh — issue the correct DPMS on/off command for whichever
#            Wayland compositor is currently active.
#
# Usage:
#   dpms.sh on   — tell the active compositor to power monitors on
#   dpms.sh off  — tell the active compositor to power monitors off
#
# Called by hypridle (services.hypridle) for the DPMS listener block
# so that a single shared hypridle config works under both Hyprland
# and Niri regardless of which compositor packages are installed.

set -euo pipefail

ACTION="${1:-}"

if [[ "$ACTION" != "on" && "$ACTION" != "off" ]]; then
    echo "Usage: dpms.sh <on|off>" >&2
    exit 1
fi

# ── Detect active compositor ──────────────────────────────────────────────────
# We probe each compositor's IPC binary; these exit non-zero / fail entirely
# when that compositor is not running, so we use || true to suppress errors
# and rely purely on the exit code.

detect_compositor() {
    if hyprctl version &>/dev/null; then
        echo "hyprland"
    elif niri msg version &>/dev/null; then
        echo "niri"
    else
        echo "unknown"
    fi
}

COMPOSITOR="$(detect_compositor)"

# ── Dispatch ──────────────────────────────────────────────────────────────────
case "$COMPOSITOR" in
hyprland)
    hyprctl dispatch dpms "$ACTION"
    ;;
niri)
    if [[ "$ACTION" == "off" ]]; then
        niri msg action power-off-monitors
    else
        niri msg action power-on-monitors
    fi
    ;;
*)
    echo "dpms.sh: could not detect active compositor (tried hyprctl, niri msg)" >&2
    exit 1
    ;;
esac
