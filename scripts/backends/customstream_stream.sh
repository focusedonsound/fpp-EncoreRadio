#!/usr/bin/env bash
# Encore Radio - Custom Internet Radio Stream backend (free tier).
#
# Same relay pattern as tunein_stream.sh, but the URL is typed in directly
# by the owner instead of resolved from a station search - covers any
# plain HTTP/HLS internet radio stream that isn't in TuneIn's directory.

set -euo pipefail

CFG_FILE="/home/fpp/media/config/encoreradio.json"
LOG_FILE="${MEDIADIR:-/home/fpp/media}/logs/plugin-fpp-EncoreRadio.log"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [customstream] $*" >> "$LOG_FILE"; }

STREAM_URL="$(python3 -c "
import json
try:    print(json.load(open('$CFG_FILE')).get('customstream', {}).get('streamUrl', ''))
except: print('')
" 2>/dev/null || echo "")"

if [[ -z "$STREAM_URL" ]]; then
    log "ERROR: no custom stream configured (customstream.streamUrl is empty)"
    exit 1
fi

log "Starting relay for custom stream: $STREAM_URL"
"${HERE}/er_relay.sh" start url "$STREAM_URL"
