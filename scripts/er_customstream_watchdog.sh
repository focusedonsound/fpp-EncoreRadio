#!/usr/bin/env bash
# Encore Radio - Internet Radio failover watchdog (free).
#
# Only relevant when source == customstream and 2+ stations are configured
# (the active station plus at least one Saved Station) - polls playback
# liveness and, if the stream has died, advances to the next station in
# the chain (active + saved, in order, wrapping around) and restarts.
#
# Deliberately separate from er_playback_scheduler.sh: that watchdog is
# premium and swaps between source *types* (spotify/pandora/etc) on a
# schedule or on failure. This one is free and scoped to a single source
# type - multiple Internet Radio URLs with automatic failover between them
# is parity with what other plugins already offer for free, not a premium
# capability in its own right.

set -uo pipefail

CFG_FILE="/home/fpp/media/config/encoreradio.json"
STATE_DIR="/home/fpp/media/plugins/fpp-EncoreRadio/state"
LOG_FILE="${MEDIADIR:-/home/fpp/media}/logs/plugin-fpp-EncoreRadio.log"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLL_SECONDS=30

# shellcheck source=lib_playback_schedule.sh
source "${HERE}/lib_playback_schedule.sh"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [customstream-watchdog] $*" >> "$LOG_FILE"; }

log "Internet Radio failover watchdog starting (pid=$$)"
while true; do
    sleep "$POLL_SECONDS"

    SRC="$(er_active_source)"
    [[ "$SRC" != "customstream" ]] && continue
    er_playback_alive customstream && continue

    CUR_URL="$(python3 -c "
import json
try:    print(json.load(open('$CFG_FILE')).get('customstream', {}).get('streamUrl', ''))
except: print('')
" 2>/dev/null)"

    NEXT_JSON="$(er_next_customstream_target "$CUR_URL")"
    if [[ -z "$NEXT_JSON" ]]; then
        log "Stream appears to have died but no other station is configured - nothing to fail over to"
        continue
    fi

    NEXT_NAME="$(NEXT_JSON="$NEXT_JSON" python3 -c "
import json, os
print(json.loads(os.environ['NEXT_JSON']).get('name', ''))
" 2>/dev/null)"
    log "Stream '$CUR_URL' appears to have died - failing over to '$NEXT_NAME'"

    er_set_customstream_active "$NEXT_JSON"
    bash "${HERE}/er_stop_playback.sh"
    sleep 1
    bash "${HERE}/er_start_source.sh" customstream
done
