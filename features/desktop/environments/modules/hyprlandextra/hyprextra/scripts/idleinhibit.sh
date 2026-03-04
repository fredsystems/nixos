#!/usr/bin/env bash
set -euo pipefail

if systemctl --user --quiet is-active caffeine-inhibit.service; then
    systemctl --user stop caffeine-inhibit.service
else
    systemctl --user start caffeine-inhibit.service
fi
