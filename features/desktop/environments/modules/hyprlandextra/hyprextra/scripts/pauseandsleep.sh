#!/usr/bin/env bash

# Ask logind to lock the session. The active shell's locker answers it:
# hypridle (lock_cmd = hyprlock) under wayle, Noctalia's lock screen under
# Noctalia.
playerctl pause
loginctl lock-session
