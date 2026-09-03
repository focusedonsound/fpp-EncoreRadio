#!/usr/bin/env bash
# Encore Radio - FPP 9.x playback path.
#
# Plays the local relay URL into the PulseAudio sink via ffplay - the same
# audio path Announcement Assistant expects to duck (it fades whatever's
# an active PulseAudio sink-input, not just FPP's own show audio).

set -euo pipefail

CFG_FILE="/home/fpp/media/config/encoreradio.json"
STATE_DIR="/home/fpp/media/plugins/fpp-EncoreRadio/state"
LOG_FILE="/home/fpp/media/logs/EncoreRadio.log"
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
echo $! > "$PID_FILE"
log "ffplay started pid=$(cat "$PID_FILE")"
