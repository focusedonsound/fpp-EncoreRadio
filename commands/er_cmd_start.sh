#!/bin/bash
# FPP Command: Encore Radio - Start
#
# Reads the configured source, starts that backend (which feeds the local
# relay), then plays the relay via PulseAudio.
#
# One playback path for both FPP versions: originally this branched on
# FPP 10.x's "Play Media"/Stream Slot command vs. FPP 9.x's PulseAudio sink,
# but real-hardware testing showed that command's actual C++ implementation
# uses `filesrc location=...` (FalconChristmas/fpp
# src/mediaoutput/GStreamerOut.cpp) - a local-file-only GStreamer source, not
# a network-capable one - so it can never play our relay's http:// URL. FPP
# 10.x's PipeWire stack ships its own pulse-compat socket
# (pipewire-pulse), confirmed working end-to-end on a real 10.x box, so
# plain PulseAudio playback (er_play_pulse.sh) works unchanged on both
# versions and there's no need to detect which one we're on.

set -euo pipefail

CFG_FILE="/home/fpp/media/config/encoreradio.json"
LOG_FILE="/home/fpp/media/logs/EncoreRadio.log"
PLUGIN_DIR="$(dirname "$(dirname "$0")")"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [fpp-cmd-start] $*" >> "$LOG_FILE"; }

if [[ ! -f "$CFG_FILE" ]]; then
    log "ERROR: config not found: $CFG_FILE"
    exit 1
fi

SOURCE="$(python3 -c "
import json
try:    print(json.load(open('$CFG_FILE')).get('source', ''))
except: print('')
" 2>/dev/null || echo "")"

case "$SOURCE" in
    tunein)
        BACKEND_SCRIPT="${PLUGIN_DIR}/scripts/backends/tunein_stream.sh"
        ;;
    pandora)
        BACKEND_SCRIPT="${PLUGIN_DIR}/scripts/backends/pandora_pianobar.sh"
        ;;
    spotify)
        log "ERROR: Spotify backend not yet implemented (premium, milestone M3)"
        exit 1
        ;;
    *)
        log "ERROR: no source configured (encoreradio.json 'source' is empty)"
        exit 1
        ;;
esac

log "START source=$SOURCE"
bash "$BACKEND_SCRIPT"

# Give the relay a moment to come up before handing its URL to the playback
# path - ffmpeg's -listen HTTP server needs to be accepting connections
# first.
sleep 2

bash "${PLUGIN_DIR}/scripts/er_play_pulse.sh"

STATE_DIR="/home/fpp/media/plugins/fpp-EncoreRadio/state"
mkdir -p "$STATE_DIR" 2>/dev/null || true
ANNOUNCE_PID_FILE="${STATE_DIR}/announce_scheduler.pid"

if [[ -f "$ANNOUNCE_PID_FILE" ]] && kill -0 "$(cat "$ANNOUNCE_PID_FILE" 2>/dev/null)" 2>/dev/null; then
    log "Announcement scheduler already running, leaving it be"
else
    nohup bash "${PLUGIN_DIR}/scripts/er_announce_scheduler.sh" >> "$LOG_FILE" 2>&1 &
    echo $! > "$ANNOUNCE_PID_FILE"
    log "Announcement scheduler started pid=$(cat "$ANNOUNCE_PID_FILE")"
fi
