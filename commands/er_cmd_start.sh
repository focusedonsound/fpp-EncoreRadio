#!/bin/bash
# FPP Command: Encore Radio - Start
#
# Reads the configured source, starts that backend (which feeds the local
# relay), then plays the relay through whichever path FPP supports (10.x
# Stream Slot / Play Media, or 9.x PulseAudio via ffplay).

set -euo pipefail

CFG_FILE="/home/fpp/media/config/encoreradio.json"
LOG_FILE="/home/fpp/media/logs/EncoreRadio.log"
PLUGIN_DIR="$(dirname "$(dirname "$0")")"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [fpp-cmd-start] $*" >> "$LOG_FILE"; }

source "${PLUGIN_DIR}/scripts/lib_backend_detect.sh"

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

if er_pipewire_slots_available; then
    log "Backend=PipeWire/Stream Slots (FPP 10.x)"
    bash "${PLUGIN_DIR}/scripts/er_play_pipewire.sh"
else
    log "Backend=PulseAudio (FPP 9.x)"
    bash "${PLUGIN_DIR}/scripts/er_play_pulse.sh"
fi

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
