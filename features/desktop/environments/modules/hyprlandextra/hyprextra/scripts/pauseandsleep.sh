#!/usr/bin/env bash

# Ask logind to lock the session; Noctalia's lock screen answers it.
playerctl pause
loginctl lock-session
