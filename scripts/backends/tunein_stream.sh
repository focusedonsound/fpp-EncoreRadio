#!/usr/bin/env bash
# Encore Radio - TuneIn backend (free tier).
#
# TuneIn stations are plain HTTP/HLS stream URLs - no login, no SDK. The
# owner picks a station in the UI (www/search_tunein.php resolves the
# station's direct stream URL and saves it into config), so this script's
# only job is to hand that URL to the relay.

set -euo pipefail

CFG_FILE="/home/fpp/media/config/encoreradio.json"
LOG_FILE="/home/fpp/media/logs/EncoreRadio.log"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [tunein] $*" >> "$LOG_FILE"; }

STREAM_URL="$(python3 -c "
import json
try:    print(json.load(open('$CFG_FILE')).get('tunein', {}).get('streamUrl', ''))
except: print('')
" 2>/dev/null || echo "")"

if [[ -z "$STREAM_URL" ]]; then
    log "ERROR: no TuneIn station configured (tunein.streamUrl is empty)"
    exit 1
fi

log "Starting relay for TuneIn: $STREAM_URL"
"${HERE}/er_relay.sh" start url "$STREAM_URL"
