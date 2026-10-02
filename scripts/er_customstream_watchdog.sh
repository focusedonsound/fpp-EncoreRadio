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

CFG_FILE="/home/fpp/media/plugindata/fpp-EncoreRadio/encoreradio.json"
STATE_DIR="/home/fpp/media/plugins/fpp-EncoreRadio/state"
LOG_FILE="${MEDIADIR:-/home/fpp/media}/logs/plugin-fpp-EncoreRadio.log"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLL_SECONDS=30

# shellcheck source=lib_playback_schedule.sh
source "${HERE}/lib_playback_schedule.sh"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [customstream-watchdog] $*" >> "$LOG_FILE"; }

# Self-exclusion, not just the launcher's own check: er_cmd_start.sh checks
# "is the PID in customstream_watchdog.pid still alive" before launching a
# new instance, but that check-then-launch isn't atomic - two Start
# dispatches landing close together (a double-tap, or two Schedule entries
# firing within the same second) can both read the pid file, both see
# nothing alive, and both launch. Whichever writes the pid file second
# "wins" it, but the first instance never finds out it lost and keeps
# running forever as an untracked orphan - er_stop.sh's kill_pid_file only
# ever kills whatever pid happens to be in the file, so that orphan
# survives every future Stop too, still polling and still able to fire a
# station failover the operator has no way to see coming or turn off
# short of a reboot. flock here is atomic regardless of how many copies
# start at once - only the one that actually gets the lock continues;
# every other exits immediately rather than running a duplicate loop.
LOCK_FILE="${STATE_DIR}/customstream_watchdog.lock"
exec 9>"$LOCK_FILE" || { log "ERROR: could not open lock file $LOCK_FILE"; exit 1; }
if ! flock -n 9; then
    log "Another Internet Radio failover watchdog instance already holds the lock - exiting (pid=$$)"
    exit 0
fi

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
