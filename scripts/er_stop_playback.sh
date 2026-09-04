#!/usr/bin/env bash
# Encore Radio - stop CURRENT playback only (relay, backend process,
# network share mount, Spotify pause+usage finalize) WITHOUT touching the
# announcement scheduler or writing "Stop complete" - that's er_stop.sh's
# job for a real Stop. This is the shared primitive both er_stop.sh and
# the Rotation/Fallback watchdog (er_playback_scheduler.sh) call: a real
# Stop tears everything down; a rotation/fallback source swap only needs
# to tear down playback before starting the next source.
#
# Reads which source is actually active from state/active.json (written
# by er_start_source.sh) rather than the config file's static "source"
# field, since with Rotation/Fallback enabled the two can differ - the
# config's "source" is just the fallback/default, not necessarily what's
# playing right now.

set -uo pipefail

STATE_DIR="/home/fpp/media/plugins/fpp-EncoreRadio/state"
LOG_FILE="/home/fpp/media/logs/EncoreRadio.log"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [stop-playback] $*" >> "$LOG_FILE"; }

ACTIVE_SOURCE="$(python3 -c "
import json
try:    print(json.load(open('${STATE_DIR}/active.json')).get('source', ''))
except: print('')
" 2>/dev/null || echo "")"
if [[ -z "$ACTIVE_SOURCE" ]]; then
    ACTIVE_SOURCE="$(python3 -c "
import json
try:    print(json.load(open('/home/fpp/media/config/encoreradio.json')).get('source', ''))
except: print('')
" 2>/dev/null || echo "")"
fi

log "Stopping playback (active source: ${ACTIVE_SOURCE:-none})"

if [[ -f "${STATE_DIR}/playback.pid" ]]; then
    kill "$(cat "${STATE_DIR}/playback.pid" 2>/dev/null)" 2>/dev/null || true
    rm -f "${STATE_DIR}/playback.pid"
fi

if [[ -f "${STATE_DIR}/pianobar.pid" ]]; then
    if [[ -p "${STATE_DIR}/pianobar.fifo" ]]; then
        echo "q" > "${STATE_DIR}/pianobar.fifo" 2>/dev/null || true
        sleep 1
    fi
    kill "$(cat "${STATE_DIR}/pianobar.pid" 2>/dev/null)" 2>/dev/null || true
    rm -f "${STATE_DIR}/pianobar.pid"
fi

"${HERE}/er_relay.sh" stop >/dev/null 2>&1 || true

# No sudo needed - this script is only ever reached via an actual FPP
# Command, which fppd already runs as root (see netshare_folder.sh for the
# full explanation).
NETSHARE_MOUNT="${STATE_DIR}/netshare_mount"
if mountpoint -q "$NETSHARE_MOUNT" 2>/dev/null; then
    umount "$NETSHARE_MOUNT" 2>/dev/null || umount -l "$NETSHARE_MOUNT" 2>/dev/null || true
fi

if [[ "$ACTIVE_SOURCE" == "spotify" ]]; then
    TOKEN="$(bash "${HERE}/spotify_token.sh" 2>/dev/null)"
    if [[ -n "$TOKEN" ]]; then
        curl -s -m 10 -X PUT "https://api.spotify.com/v1/me/player/pause" \
            -H "Authorization: Bearer ${TOKEN}" >> "$LOG_FILE" 2>&1 || true
    fi
fi

if [[ "$ACTIVE_SOURCE" == "spotify" || "$ACTIVE_SOURCE" == "pandora" ]]; then
    bash "${HERE}/er_track_usage.sh" finalize
fi

rm -f "${STATE_DIR}/active.json"
log "Playback stopped"
