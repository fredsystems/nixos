#!/usr/bin/env bash
# niri-swap-external.sh — toggle a portable external monitor between the
#                          left and right side of the laptop's built-in
#                          display under niri.
#
# niri has no auto-right/auto-left placement keyword like Hyprland; outputs
# are positioned by explicit logical x/y coordinates. This script flips the
# external monitor from one side of the internal panel to the other on each
# invocation by re-applying transient `niri msg output ... position set`
# commands.
#
# Name resolution caveat: niri config files match outputs by their
# "make model serial" string (e.g. "Genesys ATE Inc PM156R1-H"), but the
# `niri msg output` IPC command and the `niri msg --json outputs` payload
# key outputs by their *connector* name (e.g. "DP-1"). So this script
# identifies the external monitor by its make/model fields in the JSON, then
# drives the position changes via the resolved connector name.
#
# Logical widths are read live from `niri msg --json outputs` rather than
# hardcoded. niri may apply a different effective scale than the config
# requests (e.g. snapping 1.5 -> 1.75), which changes the logical width.
# Hardcoding it leaves a gap between the two outputs, and the cursor can
# only cross between directly-adjacent (flush) outputs — a gap traps the
# pointer at the edge. Computing placement from the actual logical width
# keeps the outputs flush in both layouts.
#
# Layouts (W_int = internal logical width, W_ext = external logical width):
#   external-right (default): eDP-1 at x=0,     external at x=W_int
#   external-left           : external at x=0,  eDP-1    at x=W_ext

set -euo pipefail

# Built-in panel connector (stable across boots).
INTERNAL="eDP-1"

# External monitor identity, matched against the JSON `make`/`model` fields.
EXTERNAL_MAKE="Genesys ATE Inc"
EXTERNAL_MODEL="PM156R1-H"

if ! niri msg version &>/dev/null; then
    echo "niri-swap-external.sh: niri is not running" >&2
    exit 1
fi

OUTPUTS_JSON="$(niri msg --json outputs)"

# Resolve the external monitor's connector name (e.g. "DP-1") by matching
# its make and model. Empty if it is not currently connected.
EXTERNAL="$(
    echo "$OUTPUTS_JSON" |
        jq -r --arg make "$EXTERNAL_MAKE" --arg model "$EXTERNAL_MODEL" \
            'to_entries[]
               | select(.value.make == $make and .value.model == $model)
               | .value.name' |
        head -n1
)"

if [[ -z "$EXTERNAL" ]]; then
    echo "niri-swap-external.sh: external monitor '$EXTERNAL_MAKE $EXTERNAL_MODEL' not connected" >&2
    exit 0
fi

# Helper: read a logical geometry field for a given connector name.
logical_field() {
    local name="$1" field="$2"
    echo "$OUTPUTS_JSON" |
        jq -r --arg name "$name" --arg field "$field" \
            'to_entries[] | select(.value.name == $name) | .value.logical[$field] // 0'
}

# Live logical widths (account for whatever scale niri actually applied).
INTERNAL_WIDTH="$(logical_field "$INTERNAL" width)"
EXTERNAL_WIDTH="$(logical_field "$EXTERNAL" width)"
current_x="$(logical_field "$EXTERNAL" x)"

# Decide the target layout. If the external monitor currently sits to the
# right of the internal panel (x >= internal width), move it to the left;
# otherwise move it to the right. In both cases the second output is placed
# flush against the first so the cursor can cross between them.
if [[ "$current_x" -ge "$INTERNAL_WIDTH" ]]; then
    # Currently right -> move external to the left, internal flush to its right.
    niri msg output "$EXTERNAL" position set 0 0
    niri msg output "$INTERNAL" position set "$EXTERNAL_WIDTH" 0
else
    # Currently left/overlapping -> external flush to the right of internal.
    niri msg output "$INTERNAL" position set 0 0
    niri msg output "$EXTERNAL" position set "$INTERNAL_WIDTH" 0
fi
