#!/usr/bin/env bash
# Encore Radio - premium (Pandora, Spotify) usage-time tracking.
#
# Entirely local, and stays that way: this is a trial-hour counter, not a
# usage-reporting endpoint - nothing here is ever sent to the license
# server or anywhere else. Deliberately resettable by anyone willing to
# edit or delete trial_state.json by hand; that's the accepted trade-off
# for not phoning home.
#
# Usage:
#   er_track_usage.sh start     - call when premium playback actually begins
#   er_track_usage.sh finalize  - call when it stops; adds elapsed time to
#                                  the persistent trial-hour counter

set -uo pipefail

STATE_DIR="/home/fpp/media/plugins/fpp-EncoreRadio/state"
TRIAL_FILE="/home/fpp/media/plugindata/fpp-EncoreRadio/trial_state.json"
LOG_FILE="${MEDIADIR:-/home/fpp/media}/logs/plugin-fpp-EncoreRadio.log"
SESSION_FILE="${STATE_DIR}/premium_session_start"

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
try:
    trial = json.load(open('$TRIAL_FILE'))
except Exception:
    trial = {}
total = int(trial.get('trialSecondsUsed', 0)) + $ELAPSED
trial['trialSecondsUsed'] = total
tmp = '$TRIAL_FILE.tmp'
json.dump(trial, open(tmp, 'w'), indent=2)
import os
os.replace(tmp, '$TRIAL_FILE')
os.chmod('$TRIAL_FILE', 0o600)
print(total)
" 2>/dev/null)"

        log "Premium session ended: +${ELAPSED}s (total used: ${NEW_TOTAL}s)"
        ;;
    *)
        echo "Usage: $0 {start|finalize}" >&2
        exit 2
        ;;
esac
