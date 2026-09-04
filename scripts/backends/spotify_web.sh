#!/usr/bin/env bash
# Encore Radio - Spotify backend (premium tier), via Raspotify + Web API.
#
# Unlike TuneIn/Pandora, there's no local relay here: Raspotify (a
# packaged librespot) runs as its own permanent system service, output
# routed to PulseAudio directly, and appears as a Spotify Connect device
# at all times. This script's only job is to tell the Spotify Web API
# "play this playlist on that device" - the same call a phone/desktop app
# would make when casting to a speaker.
#
# Two separate one-time setup steps this depends on (see www/index.php):
#   1. The owner's own Spotify Developer App, OAuth-authorized via
#      spotify_auth.php/spotify_callback.php - authenticates OUR Web API
#      calls (this script, and search_spotify.php).
#   2. Zeroconf-pairing the Raspotify device once via the owner's own
#      Spotify app on the same network - authenticates Raspotify itself.
# Neither substitutes for the other.

set -uo pipefail

CFG_FILE="/home/fpp/media/config/encoreradio.json"
LOG_FILE="${MEDIADIR:-/home/fpp/media}/logs/plugin-fpp-EncoreRadio.log"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [spotify] $*" >> "$LOG_FILE"; }

cfg() {
    python3 -c "
import json
try:    print(json.load(open('$CFG_FILE')).get('spotify', {}).get('$1', ''))
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

PLAYLIST_URI="$(cfg playlistUri)"
DEVICE_NAME="$(cfg deviceName)"

if [[ -z "$PLAYLIST_URI" ]]; then
    log "ERROR: no Spotify playlist configured (spotify.playlistUri is empty)"
    exit 1
fi
if [[ -z "$DEVICE_NAME" ]]; then
    log "ERROR: no Raspotify device name recorded (spotify.deviceName is empty) - was Raspotify installed correctly?"
    exit 1
fi

if ! systemctl is-active --quiet raspotify.service 2>/dev/null; then
    log "ERROR: raspotify.service is not running - install/pairing may be incomplete"
    exit 1
fi

TOKEN="$(bash "${HERE}/spotify_token.sh")"
if [[ -z "$TOKEN" ]]; then
    log "ERROR: could not obtain a Spotify access token"
    exit 1
fi

# Find our Raspotify device's current device_id - it changes across
# restarts/pairings, so this is always looked up fresh rather than cached.
DEVICE_ID="$(curl -s -m 10 "https://api.spotify.com/v1/me/player/devices" \
    -H "Authorization: Bearer ${TOKEN}" | python3 -c "
import json, sys
try:
    devices = json.load(sys.stdin).get('devices', [])
    for d in devices:
        if d.get('name') == '$DEVICE_NAME':
            print(d['id'])
            break
except Exception:
    pass
")"

if [[ -z "$DEVICE_ID" ]]; then
    log "ERROR: Raspotify device '$DEVICE_NAME' not found in Spotify's device list - has it been paired yet? (open Spotify on your phone, on the same network, and select it once from the Connect device list)"
    exit 1
fi

log "Playing $PLAYLIST_URI on device '$DEVICE_NAME' (id=$DEVICE_ID)"
HTTP_CODE="$(curl -s -o /tmp/encoreradio_spotify_play.json -w '%{http_code}' -m 10 \
    -X PUT "https://api.spotify.com/v1/me/player/play?device_id=${DEVICE_ID}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"context_uri\":\"${PLAYLIST_URI}\"}")"

if [[ "$HTTP_CODE" != "204" && "$HTTP_CODE" != "200" ]]; then
    log "ERROR: Spotify play request failed (HTTP $HTTP_CODE): $(cat /tmp/encoreradio_spotify_play.json 2>/dev/null)"
    exit 1
fi

log "Playback started"
bash "${HERE}/er_track_usage.sh" start

# "volume" is a top-level config field (shared across all sources), not
# under "spotify" - unlike the cfg() helper above which only reads spotify.*
VOLUME="$(python3 -c "
import json
try:    print(int(json.load(open('$CFG_FILE')).get('volume', 70)))
except: print(70)
" 2>/dev/null || echo 70)"

curl -s -m 10 -X PUT "https://api.spotify.com/v1/me/player/volume?volume_percent=${VOLUME}&device_id=${DEVICE_ID}" \
    -H "Authorization: Bearer ${TOKEN}" >> "$LOG_FILE" 2>&1 || log "WARNING: failed to set Spotify volume"
