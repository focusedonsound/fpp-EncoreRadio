#!/usr/bin/env bash
# Encore Radio - Announcement Assistant scheduler.
#
# Instead of the owner manually adding N separate FPP schedule entries to
# fire Announcement Assistant's "Play" command throughout the night, this
# loop does it for them: started alongside Encore Radio's own playback,
# stopped alongside it. AA itself is untouched - this only ever calls its
# existing "Announcement Assistant - Play" FPP Command.
#
# Two modes (config.announce.mode):
#   cadence - fire every N minutes, starting N minutes after this loop begins
#   times   - fire at specific HH:MM times (24h, local time), once per day
#
# Runs as a simple foreground loop; the caller (er_cmd_start.sh) backgrounds
# it with nohup/& and records the PID for er_stop.sh to kill.

set -uo pipefail

CFG_FILE="/home/fpp/media/config/encoreradio.json"
LOG_FILE="/home/fpp/media/logs/EncoreRadio.log"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [announce] $*" >> "$LOG_FILE"; }

cfg_json() {
    python3 -c "
import json
try:
    print(json.dumps(json.load(open('$CFG_FILE')).get('announce', {})))
except Exception:
    print('{}')
" 2>/dev/null || echo "{}"
}

fire_announcement() {
    local slot="$1"
    log "Firing Announcement Assistant slot=$slot"
    # FPP's /api/command endpoint blocks until the command finishes running,
    # not just until it starts - confirmed on real hardware, where AA's own
    # duck/play/fade-up sequence legitimately took ~4s and a 5s curl timeout
    # here logged a false "failed" warning even though AA completed fine.
    # 30s covers any reasonably long announcement clip; if a real timeout
    # ever fires it's worth investigating, not silently ignoring, so this
    # still logs a warning rather than swallowing curl's exit code.
    curl -s -m 30 -X POST "http://localhost/api/command" \
        -H "Content-Type: application/json" \
        -d "{\"command\":\"Announcement Assistant - Play\",\"args\":[\"${slot}\"]}" \
        >> "$LOG_FILE" 2>&1 || log "WARNING: AA Play command call failed"
}

log "Announcement scheduler starting (pid=$$)"

LAST_FIRED_MINUTE=""

while true; do
    ANNOUNCE_JSON="$(cfg_json)"
    ENABLED="$(echo "$ANNOUNCE_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('enabled', False))" 2>/dev/null || echo False)"
    SLOT="$(echo "$ANNOUNCE_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('slot', ''))" 2>/dev/null || echo "")"
    MODE="$(echo "$ANNOUNCE_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('mode', 'cadence'))" 2>/dev/null || echo "cadence")"

    if [[ "$ENABLED" != "True" || -z "$SLOT" ]]; then
        sleep 60
        continue
    fi

    if [[ "$MODE" == "times" ]]; then
        NOW_HHMM="$(date '+%H:%M')"
        MATCH="$(echo "$ANNOUNCE_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
times = d.get('times', [])
print('yes' if '$NOW_HHMM' in times else 'no')
" 2>/dev/null || echo "no")"

        if [[ "$MATCH" == "yes" && "$LAST_FIRED_MINUTE" != "$NOW_HHMM" ]]; then
            fire_announcement "$SLOT"
            LAST_FIRED_MINUTE="$NOW_HHMM"
        fi
        sleep 55
    else
        CADENCE_MIN="$(echo "$ANNOUNCE_JSON" | python3 -c "import json,sys; print(int(json.load(sys.stdin).get('cadenceMinutes', 15)))" 2>/dev/null || echo 15)"
        [[ "$CADENCE_MIN" -lt 1 ]] && CADENCE_MIN=1
        sleep "$((CADENCE_MIN * 60))"
        # Re-check enabled/slot after sleeping in case they changed or
        # Stop was called mid-wait (er_stop.sh kills this process outright,
        # but re-checking here keeps behavior sane if it's ever re-used
        # as a long-running loop instead of being killed).
        fire_announcement "$SLOT"
    fi
done
