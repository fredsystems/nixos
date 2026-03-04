#!/run/current-system/sw/bin/bash

# we are using absolute paths and a weird shabang for this script because
# it's being run (now) in the systemd context so instead of fucking around with
# $PATH and like that we can just use absolute paths and the weird shabang to inherit
# some environment variables

/etc/profiles/per-user/fred/bin/swayidle -w \
    timeout 300 '/etc/profiles/per-user/fred/bin/swaylock -f -c 000000' \
    timeout 600 '/etc/profiles/per-user/fred/bin/hyprctl dispatch dpms off' \
    resume '/etc/profiles/per-user/fred/bin/hyprctl dispatch dpms on' \
    timeout 900 '/run/current-system/sw/bin/systemctl suspend' \
    before-sleep '/etc/profiles/per-user/fred/bin/swaylock -f -c 000000'
