#!/usr/bin/env bash
# Encore Radio - FPP 10.x playback path.
#
# Plays the local relay URL through FPP's own native "Play Media" Stream
# Slot command (src/commands/MediaCommands.cpp in FalconChristmas/fpp) -
# GStreamer's uridecodebin accepts network URIs, so no direct PipeWire code
# is needed here; volume/stop/sync all come from FPP's own command surface.
#
# NOTE (open item): the exact /api/command POST body shape below is FPP's
# documented Command API convention (POST /api/command with a JSON
# {"command":..., "args":[...]} body) - confirm against a live FPP 10.x
# install during M1 verification before relying on this in production.

set -euo pipefail

CFG_FILE="/home/fpp/media/config/encoreradio.json"
STATE_DIR="/home/fpp/media/plugins/fpp-EncoreRadio/state"
LOG_FILE="/home/fpp/media/logs/EncoreRadio.log"
SLOT_FILE="${STATE_DIR}/stream_slot"

mkdir -p "$STATE_DIR" 2>/dev/null || true

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [pipewire-play] $*" >> "$LOG_FILE"; }

relay_port() {
    python3 -c "
import json
try:    print(int(json.load(open('$CFG_FILE')).get('relay', {}).get('port', 8123)))
except: print(8123)
" 2>/dev/null || echo 8123
}

VOLUME="$(python3 -c "
import json
try:    print(int(json.load(open('$CFG_FILE')).get('volume', 70)))
except: print(70)
" 2>/dev/null || echo 70)"

# Slot 1 is fine here: Encore Radio only ever runs when the show doesn't
# (see build plan - no dedicated slot reservation needed).
SLOT=1
echo "$SLOT" > "$SLOT_FILE"

URL="http://127.0.0.1:$(relay_port)/stream"

log "Play Media url=$URL slot=$SLOT volume=$VOLUME"
curl -s -m 5 -X POST "http://localhost/api/command" \
    -H "Content-Type: application/json" \
    -d "{\"command\":\"Play Media\",\"args\":[\"${URL}\",\"1\",\"0\",\"${SLOT}\"]}" \
    >> "$LOG_FILE" 2>&1 || log "WARNING: Play Media command call failed"

curl -s -m 5 -X POST "http://localhost/api/command" \
    -H "Content-Type: application/json" \
    -d "{\"command\":\"Set Slot Volume\",\"args\":[\"${SLOT}\",\"${VOLUME}\"]}" \
    >> "$LOG_FILE" 2>&1 || log "WARNING: Set Slot Volume command call failed"
