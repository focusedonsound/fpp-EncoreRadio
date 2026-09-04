#!/usr/bin/env bash
# Encore Radio - FPP 9.x playback path.
#
# Plays the local relay URL into the PulseAudio sink via ffplay - the same
# audio path Announcement Assistant expects to duck (it fades whatever's
# an active PulseAudio sink-input, not just FPP's own show audio).

set -euo pipefail

CFG_FILE="/home/fpp/media/config/encoreradio.json"
STATE_DIR="/home/fpp/media/plugins/fpp-EncoreRadio/state"
LOG_FILE="${MEDIADIR:-/home/fpp/media}/logs/plugin-fpp-EncoreRadio.log"
PID_FILE="${STATE_DIR}/playback.pid"

mkdir -p "$STATE_DIR" 2>/dev/null || true

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [pulse-play] $*" >> "$LOG_FILE"; }

relay_port() {
    python3 -c "
import json
try:    print(int(json.load(open('$CFG_FILE')).get('relay', {}).get('port', 8123)))
except: print(8123)
" 2>/dev/null || echo 8123
}

URL="http://127.0.0.1:$(relay_port)/stream"

if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
    kill "$(cat "$PID_FILE")" 2>/dev/null || true
    sleep 0.5
fi

log "Playing via ffplay into PulseAudio: $URL"
# ffplay has no -ao flag (that's mpv/mplayer) - it outputs through SDL,
# so PulseAudio is selected via SDL_AUDIODRIVER, not a command-line arg.
nohup env SDL_AUDIODRIVER=pulseaudio ffplay -nodisp -autoexit -loglevel warning "$URL" \
    >> "$LOG_FILE" 2>&1 &
FFPLAY_PID=$!
echo "$FFPLAY_PID" > "$PID_FILE"
log "ffplay started pid=$FFPLAY_PID"

VOLUME="$(python3 -c "
import json
try:    print(int(json.load(open('$CFG_FILE')).get('volume', 70)))
except: print(70)
" 2>/dev/null || echo 70)"

# ffplay's sink-input doesn't exist until PulseAudio has actually connected
# it - poll briefly rather than assuming a fixed delay is enough.
for _ in $(seq 1 20); do
    SINK_IDX="$(pactl -f json list sink-inputs 2>/dev/null | python3 -c "
import json, sys
try:
    for si in json.load(sys.stdin):
        if str(si.get('properties', {}).get('application.process.id', '')) == '$FFPLAY_PID':
            print(si['index'])
            break
except Exception:
    pass
" 2>/dev/null)"
    [[ -n "$SINK_IDX" ]] && break
    sleep 0.25
done

if [[ -n "$SINK_IDX" ]]; then
    pactl set-sink-input-volume "$SINK_IDX" "${VOLUME}%" 2>/dev/null || true
    log "Set volume to ${VOLUME}%"
else
    log "WARNING: could not find ffplay's sink-input to set volume (it may still be at PulseAudio's default)"
fi
