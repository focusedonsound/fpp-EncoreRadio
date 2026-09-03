#!/usr/bin/env bash
# Encore Radio - premium (Spotify) usage-time tracking.
#
# Usage:
#   er_track_usage.sh start     - call when premium playback actually begins
#   er_track_usage.sh finalize  - call when it stops; adds elapsed time to
#                                  the persistent trial-hour counter

set -uo pipefail

CFG_FILE="/home/fpp/media/config/encoreradio.json"
STATE_DIR="/home/fpp/media/plugins/fpp-EncoreRadio/state"
LOG_FILE="/home/fpp/media/logs/EncoreRadio.log"
SESSION_FILE="${STATE_DIR}/premium_session_start"
LICENSE_SERVER_BASE="https://encoreradio-license.nscilingo.workers.dev/api"

mkdir -p "$STATE_DIR" 2>/dev/null || true

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [usage] $*" >> "$LOG_FILE"; }

case "${1:-}" in
    start)
        date +%s > "$SESSION_FILE"
        log "Premium session started"
        ;;
    finalize)
        [[ -f "$SESSION_FILE" ]] || exit 0
        START="$(cat "$SESSION_FILE" 2>/dev/null || echo "")"
        rm -f "$SESSION_FILE"
        [[ -z "$START" ]] && exit 0

        NOW="$(date +%s)"
        ELAPSED=$((NOW - START))
        [[ "$ELAPSED" -lt 0 ]] && ELAPSED=0

        NEW_TOTAL="$(python3 -c "
import json
cfg = json.load(open('$CFG_FILE'))
cfg.setdefault('license', {})
total = int(cfg['license'].get('trialSecondsUsed', 0)) + $ELAPSED
cfg['license']['trialSecondsUsed'] = total
tmp = '$CFG_FILE.tmp'
json.dump(cfg, open(tmp, 'w'), indent=2)
import os
os.replace(tmp, '$CFG_FILE')
print(total)
" 2>/dev/null)"

        log "Premium session ended: +${ELAPSED}s (total used: ${NEW_TOTAL}s)"

        # Best-effort report to the license server - failure here just
        # means the next report catches it up; local tracking (above) is
        # already authoritative for this device's own trial gate.
        HWID="$(bash "$(dirname "${BASH_SOURCE[0]}")/er_hwid.sh" 2>/dev/null)"
        EMAIL="$(python3 -c "
import json
try:    print(json.load(open('$CFG_FILE')).get('license', {}).get('email', ''))
except: print('')
" 2>/dev/null)"
        curl -s -m 8 -X POST "${LICENSE_SERVER_BASE}/report-usage" \
            -H "Content-Type: application/json" \
            -d "{\"hwid\":\"${HWID}\",\"email\":\"${EMAIL}\",\"secondsUsedTotal\":${NEW_TOTAL}}" \
            >> "$LOG_FILE" 2>&1 || log "WARNING: usage report to license server failed (server may not exist yet)"
        ;;
    *)
        echo "Usage: $0 {start|finalize}" >&2
        exit 2
        ;;
esac
