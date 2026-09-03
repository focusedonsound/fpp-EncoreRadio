#!/usr/bin/env bash
# Encore Radio - Pandora backend (premium tier), via Pianobar.
#
# Pianobar is a long-standing open-source headless Pandora client - the
# same shape as librespot for Spotify: log in once (credentials live in
# config/encoreradio.json, same as any other credential field), then it
# runs unattended.
#
# NOTE (open item, flagged in the build plan): this captures Pianobar's
# audio via a dedicated PulseAudio null-sink + monitor source rather than
# guessing at libao's raw-fifo output format. On FPP 9.x this is exactly
# what PulseAudio is for. On FPP 10.x (PipeWire), whether `pactl`/`ffmpeg -f
# pulse` against the pipewire-pulse compatibility socket works the same way
# needs to be confirmed on real hardware during M1 verification - if not,
# this backend needs an alternate capture path on 10.x.

set -euo pipefail

CFG_FILE="/home/fpp/media/config/encoreradio.json"
STATE_DIR="/home/fpp/media/plugins/fpp-EncoreRadio/state"
LOG_FILE="/home/fpp/media/logs/EncoreRadio.log"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SINK_NAME="encoreradio_pandora"
PIANOBAR_CTL="${STATE_DIR}/pianobar.fifo"
PIANOBAR_PID="${STATE_DIR}/pianobar.pid"
PIANOBAR_HOME="${STATE_DIR}/pianobar_home"

mkdir -p "$STATE_DIR" "$PIANOBAR_HOME/.config/pianobar" 2>/dev/null || true

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [pandora] $*" >> "$LOG_FILE"; }

cfg() {
    python3 -c "
import json
try:    print(json.load(open('$CFG_FILE')).get('pandora', {}).get('$1', ''))
except: print('')
" 2>/dev/null || echo ""
}

# The "&& GATE_RC=0 || GATE_RC=$?" form (not a plain assignment) matters
# under `set -e`: a plain `VAR="$(cmd)"` assignment aborts the script
# immediately on cmd's nonzero exit, before GATE_RC is ever captured or
# the error below is logged - confirmed on real hardware, where a blocked
# gate exited correctly but silently, with no "ERROR:" line ever written.
GATE_MSG="$(bash "${HERE}/er_premium_gate.sh" check)" && GATE_RC=0 || GATE_RC=$?
if [[ "$GATE_RC" -ne 0 ]]; then
    log "ERROR: $GATE_MSG"
    exit 1
fi
log "Premium gate: $GATE_MSG"

USERNAME="$(cfg username)"
PASSWORD="$(cfg password)"
STATION_ID="$(cfg stationId)"

if [[ -z "$USERNAME" || -z "$PASSWORD" ]]; then
    log "ERROR: Pandora username/password not configured"
    exit 1
fi

# Isolated pianobar config (own HOME) so this plugin never touches a
# system-wide pianobar config another user/process might have.
cat > "${PIANOBAR_HOME}/.config/pianobar/config" <<EOF
user = ${USERNAME}
password = ${PASSWORD}
audio_quality = medium
EOF
chmod 600 "${PIANOBAR_HOME}/.config/pianobar/config"

ensure_null_sink() {
    if ! pactl list short sinks 2>/dev/null | grep -q "$SINK_NAME"; then
        log "Creating PulseAudio null sink: $SINK_NAME"
        pactl load-module module-null-sink sink_name="$SINK_NAME" \
            sink_properties=device.description="EncoreRadio-Pandora" >/dev/null 2>&1 || {
            log "ERROR: failed to create null sink $SINK_NAME"
            exit 1
        }
    fi
}

start_pianobar() {
    [[ -p "$PIANOBAR_CTL" ]] || mkfifo "$PIANOBAR_CTL"

    log "Starting pianobar (station=${STATION_ID:-<default>})"
    HOME="$PIANOBAR_HOME" PULSE_SINK="$SINK_NAME" \
        nohup pianobar < "$PIANOBAR_CTL" >> "$LOG_FILE" 2>&1 &
    echo $! > "$PIANOBAR_PID"

    # Keep the control fifo open for writes so pianobar doesn't see EOF
    # and exit; also lets er_stop.sh send a clean 'q' quit command later.
    exec 3>"$PIANOBAR_CTL"

    if [[ -n "$STATION_ID" ]]; then
        sleep 5
        echo "s${STATION_ID}" >&3
    fi
}

ensure_null_sink
start_pianobar
bash "${HERE}/er_track_usage.sh" start

log "Starting relay from sink monitor: ${SINK_NAME}.monitor"
"${HERE}/er_relay.sh" start pulse-source "${SINK_NAME}.monitor"
