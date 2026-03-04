#!/usr/bin/env bash
set -euo pipefail

vpn=$(nmcli -t -f NAME,TYPE,DEVICE connection show --active |
    awk -F: '$2 == "vpn" {print $1}')

if [[ -z "$vpn" ]]; then
    echo '{"text":"󰖂","class":"inactive","tooltip":"VPN disconnected"}'
    exit 0
fi

echo "{\"text\":\"󰖂\",\"class\":\"active\",\"tooltip\":\"VPN connected: $vpn\"}"
