#!/usr/bin/env bash
# Encore Radio - start playback for one specific source type.
#
# Extracted out of commands/er_cmd_start.sh so both the normal Start
# command AND the Rotation/Fallback watchdog (er_playback_scheduler.sh)
# can start "whichever source" without duplicating this logic - rotation
# swaps sources on a schedule, fallback swaps sources when one dies, and
# both need exactly this same "start source X" primitive.
#
# Usage: er_start_source.sh <customstream|netshare|tunein|pandora|spotify>
# Exit 0 on success (and writes the state/active.json header-indicator
# marker), nonzero if that source failed to start.

set -uo pipefail

CFG_FILE="/home/fpp/media/plugindata/fpp-EncoreRadio/encoreradio.json"
LOG_FILE="${MEDIADIR:-/home/fpp/media}/logs/plugin-fpp-EncoreRadio.log"
STATE_DIR="/home/fpp/media/plugins/fpp-EncoreRadio/state"
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [start-source] $*" >> "$LOG_FILE"; }

relay_port() {
    python3 -c "
import json
try:    print(int(json.load(open('$CFG_FILE')).get('relay', {}).get('port', 8123)))
except: print(8123)
" 2>/dev/null || echo 8123
}

# ffmpeg has to open/probe the remote source before it opens its local
# HTTP listen socket - for a real radio stream that routinely takes longer
# than a fixed couple of seconds, and ffplay (unlike a browser) doesn't
# retry a refused connection, it just gives up. Poll for the port actually
# in LISTEN state instead of guessing a fixed delay, so a slow remote
# stream doesn't silently lose audio on every source.
#
# This must NOT actually connect to test it: the relay is `ffmpeg -listen
# 1`, an HTTP server that accepts exactly one connection ever - a
# connect-and-close probe (e.g. bash's /dev/tcp) consumes that one slot
# itself, leaving ffplay's real connection refused right after.
wait_for_relay() {
    local port="$1" tries=40
    if ! command -v ss >/dev/null 2>&1; then
        log "WARNING: 'ss' not found, falling back to a fixed delay before playback"
        sleep 3
        return 0
    fi
    for ((i = 0; i < tries; i++)); do
        ss -ltn "sport = :${port}" 2>/dev/null | grep -q LISTEN && return 0
        sleep 0.25
    done
    return 1
}

SOURCE="${1:-}"
mkdir -p "$STATE_DIR" 2>/dev/null || true

case "$SOURCE" in
    customstream|netshare|tunein|pandora)
        if [[ "$SOURCE" == "customstream" ]]; then
            bash "${PLUGIN_DIR}/scripts/backends/customstream_stream.sh"
        elif [[ "$SOURCE" == "netshare" ]]; then
            bash "${PLUGIN_DIR}/scripts/backends/netshare_folder.sh"
        elif [[ "$SOURCE" == "tunein" ]]; then
            bash "${PLUGIN_DIR}/scripts/backends/tunein_stream.sh"
        else
            bash "${PLUGIN_DIR}/scripts/backends/pandora_pianobar.sh"
        fi
        BACKEND_RC=$?
        if [[ "$BACKEND_RC" -ne 0 ]]; then
            log "ERROR: $SOURCE backend failed to start (exit $BACKEND_RC)"
            exit "$BACKEND_RC"
        fi
        if ! wait_for_relay "$(relay_port)"; then
            log "ERROR: relay never opened its local port for $SOURCE - not starting playback"
            exit 1
        fi
        bash "${PLUGIN_DIR}/scripts/er_play_pulse.sh"
        ;;
    spotify)
        bash "${PLUGIN_DIR}/scripts/backends/spotify_web.sh"
        BACKEND_RC=$?
        if [[ "$BACKEND_RC" -ne 0 ]]; then
            log "ERROR: spotify backend failed to start (exit $BACKEND_RC)"
            exit "$BACKEND_RC"
        fi
        ;;
    *)
        log "ERROR: unknown or empty source: '$SOURCE'"
        exit 1
        ;;
esac

# Header status indicator marker (see api.php) - a human label for the
# tooltip, same lookup used previously inline in er_cmd_start.sh.
python3 -c "
import json
try:
    cfg = json.load(open('$CFG_FILE'))
except Exception:
    cfg = {}
labels = {
    'customstream': (cfg.get('customstream', {}).get('name') or 'Custom Stream'),
    'netshare': (cfg.get('netshare', {}).get('folder') or 'Network Share'),
    'tunein': (cfg.get('tunein', {}).get('stationName') or 'TuneIn'),
    'pandora': (cfg.get('pandora', {}).get('stationName') or 'Pandora'),
    'spotify': (cfg.get('spotify', {}).get('playlistName') or 'Spotify'),
}
active = {'source': '$SOURCE', 'label': labels.get('$SOURCE', '$SOURCE')}
json.dump(active, open('${STATE_DIR}/active.json', 'w'))
" 2>/dev/null || true

log "Started $SOURCE"
exit 0
