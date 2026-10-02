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
LOG_FILE="${MEDIADIR:-/home/fpp/media}/logs/plugin-fpp-EncoreRadio.log"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib_curl_secure.sh
source "${HERE}/lib_curl_secure.sh"

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
try:    print(json.load(open('/home/fpp/media/plugindata/fpp-EncoreRadio/encoreradio.json')).get('source', ''))
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

# Network Share reads the share via smbclient in a background batch
# scheduler (see netshare_batch_scheduler.sh) rather than a kernel mount -
# nothing to unmount, but the scheduler and its local staging directory
# (a few tracks fetched ahead of playback) need tearing down explicitly.
# Removing the PID file BEFORE killing the process is what actually stops
# it (its own is_current_scheduler() check looks for its PID there - see
# that script), not the kill itself, which is just to stop it promptly
# instead of waiting for its next poll.
if [[ -f "${STATE_DIR}/netshare_scheduler.pid" ]]; then
    SCHED_PID="$(cat "${STATE_DIR}/netshare_scheduler.pid" 2>/dev/null || echo "")"
    rm -f "${STATE_DIR}/netshare_scheduler.pid"
    [[ -n "$SCHED_PID" ]] && kill "$SCHED_PID" 2>/dev/null || true
fi
rm -rf "${STATE_DIR}/netshare_stage" "${STATE_DIR}/netshare_remote_list.txt" 2>/dev/null || true
rm -f "/home/fpp/media/plugindata/fpp-EncoreRadio/netshare_authfile" 2>/dev/null || true

if [[ "$ACTIVE_SOURCE" == "spotify" ]]; then
    TOKEN="$(bash "${HERE}/spotify_token.sh" 2>/dev/null)"
    if [[ -n "$TOKEN" ]]; then
        er_curl_secure "header = \"Authorization: Bearer $(er_curl_cfg_escape "$TOKEN")\"" \
            -s -m 10 -X PUT "https://api.spotify.com/v1/me/player/pause" >> "$LOG_FILE" 2>&1 || true
    fi
fi

if [[ "$ACTIVE_SOURCE" == "spotify" || "$ACTIVE_SOURCE" == "pandora" ]]; then
    bash "${HERE}/er_track_usage.sh" finalize
fi

rm -f "${STATE_DIR}/active.json"
log "Playback stopped"
