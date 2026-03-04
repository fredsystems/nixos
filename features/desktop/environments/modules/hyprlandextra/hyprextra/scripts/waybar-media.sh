#!/usr/bin/env bash
set -euo pipefail

dump=$(pw-dump)

# Mic active: Audio/Source nodes in RUNNING state
if echo "$dump" | jq -e '
  .[] | select(.type=="PipeWire:Interface:Node")
  | select(.info.state=="running")
  | select(.info.props."media.class"=="Audio/Source")
' >/dev/null; then
    echo '{"text":"󰍬","class":"mic","tooltip":"Microphone is active"}'
    exit 0
fi

# Audio playing: Audio/Sink nodes in RUNNING state
if echo "$dump" | jq -e '
  .[] | select(.type=="PipeWire:Interface:Node")
  | select(.info.state=="running")
  | select(.info.props."media.class"=="Audio/Sink")
' >/dev/null; then
    echo '{"text":"󰎆","class":"audio","tooltip":"Audio is playing"}'
    exit 0
fi

echo '{"text":"󰎆","class":"idle","tooltip":"No active media"}'
