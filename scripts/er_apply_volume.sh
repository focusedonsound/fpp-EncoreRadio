#!/usr/bin/env bash
# Encore Radio - apply a volume to whatever is currently playing, live,
# by finding its PulseAudio/PipeWire-pulse sink-input via
# state/playback.pid - the canonical "who is the active player" PID this
# plugin already uses elsewhere (see er_stop_playback.sh). Does nothing
# (exit 1, not an error) when nothing is currently playing - that's the
# normal case for a slider drag or a Save with playback stopped.
#
# Usage: er_apply_volume.sh [volume 0-100]
#   No arg: reads the configured volume from encoreradio.json.
#
# Two callers:
#   - er_play_pulse.sh, backgrounded right after starting ffplay, so a
#     generous poll window here doesn't add to Start's own response time
#     (replaces that script's old inline 5s poll, which gave up silently
#     too soon for a slow-to-connect stream - issue #4).
#   - the web UI (www/set_volume.php, and www/save.php on a full Save),
#     so moving the volume slider has an audible effect immediately
#     instead of only taking effect on the next restart (issue #4).

set -uo pipefail

CFG_FILE="/home/fpp/media/plugindata/fpp-EncoreRadio/encoreradio.json"
STATE_DIR="/home/fpp/media/plugins/fpp-EncoreRadio/state"
LOG_FILE="${MEDIADIR:-/home/fpp/media}/logs/plugin-fpp-EncoreRadio.log"
PID_FILE="${STATE_DIR}/playback.pid"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [apply-volume] $*" >> "$LOG_FILE"; }

VOLUME="${1:-}"
if [[ -z "$VOLUME" ]]; then
    VOLUME="$(python3 -c "
import json
try:    print(int(json.load(open('$CFG_FILE')).get('volume', 70)))
except: print(70)
" 2>/dev/null || echo 70)"
fi
[[ "$VOLUME" =~ ^[0-9]+$ ]] || VOLUME=70
(( VOLUME < 0 )) && VOLUME=0
(( VOLUME > 100 )) && VOLUME=100

# PID existence via /proc rather than `kill -0`: this script runs both as
# root (er_play_pulse.sh, via fppd's Command execution - which is how
# every real Start actually happens, Scheduler or otherwise) and as the
# unprivileged fpp user (the web UI, via PHP-FPM) - `kill -0` on a
# root-owned PID from fpp fails with EPERM regardless of whether the
# process exists, which isn't "not playing", it's just the wrong
# permission check. Confirmed on real hardware: every real-world Start
# (always root-owned) made every live-apply from the web UI silently
# fail at this exact check, while direct SSH testing (fpp-owned ffplay)
# never exposed it. /proc/<pid> existence needs no signal permission -
# any user can see whether the directory exists.
pid_alive() { [[ -d "/proc/$1" ]]; }

if [[ ! -f "$PID_FILE" ]]; then
    exit 1
fi
PLAYER_PID="$(cat "$PID_FILE" 2>/dev/null || echo "")"
if [[ -z "$PLAYER_PID" ]] || ! pid_alive "$PLAYER_PID"; then
    exit 1
fi

# Explicit PULSE_SERVER rather than relying on discovery: this script runs
# both as root (er_play_pulse.sh, via fppd's Command execution) and as the
# fpp user (the web UI's PHP, via PHP-FPM) - the fpp user's own
# ~/.config/pulse/client.conf pin covers the second case already, but
# being explicit for both removes any dependency on that file existing or
# PHP-FPM's exec() environment picking it up the same way a login shell
# would.
PACTL=(env PULSE_SERVER=unix:/run/pulse/native pactl)

# The player process existing doesn't mean PulseAudio has registered its
# stream yet - poll rather than assume. 60 x 0.25s = 15s, well over the
# old inline poll's 5s (issue #4: a slow-to-connect stream could outlast
# that and silently leave volume unset) - safe to be generous here since
# every caller backgrounds this script rather than waiting on it.
SINK_IDX=""
for _ in $(seq 1 60); do
    SINK_IDX="$("${PACTL[@]}" -f json list sink-inputs 2>/dev/null | python3 -c "
import json, sys
try:
    for si in json.load(sys.stdin):
        if str(si.get('properties', {}).get('application.process.id', '')) == '$PLAYER_PID':
            print(si['index'])
            break
except Exception:
    pass
" 2>/dev/null)"
    [[ -n "$SINK_IDX" ]] && break
    pid_alive "$PLAYER_PID" || exit 1
    sleep 0.25
done

if [[ -z "$SINK_IDX" ]]; then
    log "WARNING: could not find pid=${PLAYER_PID}'s sink-input within 15s - volume not applied"
    exit 1
fi

"${PACTL[@]}" set-sink-input-volume "$SINK_IDX" "${VOLUME}%" 2>/dev/null
log "Applied volume ${VOLUME}% to sink-input ${SINK_IDX} (pid=${PLAYER_PID})"
