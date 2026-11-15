#!/usr/bin/env bash
# Encore Radio - SiriusXM anti-idle keepalive watchdog.
#
# SiriusXM's streaming backend interrupts any session that's played for
# several hours with no listener interaction - the "Are you still there?"
# prompt. It's enforced SiriusXM-side (subscribers hit it on the official
# apps and on other streaming gear too), NOT a bug in this plugin or in
# aiosxm, and aiosxm already keeps the login token fresh on its own - so the
# gate isn't about the session expiring, it's about the *listener* going
# quiet. A headless overnight player can't click "yes", which is exactly the
# unattended-playback case Encore Radio exists for.
#
# This watchdog defeats the gate by periodically re-tuning: while SiriusXM is
# the active source, every `intervalMinutes` (default 180, a margin under the
# ~4h cutoff) it tears playback down and starts it again - a brand-new
# authenticated session + fresh tune, which resets SiriusXM's idle timer. The
# only cost is a brief (~a few second) audio gap at each refresh, which for
# background/overnight music is negligible.
#
# Only acts when the ACTIVE source is siriusxm (read from state/active.json),
# so it's harmless when left running across a Rotation/Fallback swap to some
# other source - it simply idles until SiriusXM is playing again. Disabled by
# setting siriusxm.keepalive.enabled = false in the config.

set -uo pipefail

CFG_FILE="/home/fpp/media/plugindata/fpp-EncoreRadio/encoreradio.json"
STATE_DIR="/home/fpp/media/plugins/fpp-EncoreRadio/state"
LOG_FILE="${MEDIADIR:-/home/fpp/media}/logs/plugin-fpp-EncoreRadio.log"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLL_SECONDS=60

# shellcheck source=lib_playback_schedule.sh
source "${HERE}/lib_playback_schedule.sh"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [sxm-keepalive] $*" >> "$LOG_FILE"; }

# Read siriusxm.keepalive.{enabled,intervalMinutes} fresh each loop so a
# toggle or interval change on the plugin page takes effect without a
# restart. Prints "<enabled>\t<intervalSeconds>"; interval clamped to a sane
# [15, 230] minute range (below 15 is pointless churn; above ~230 would drift
# past the ~4h gate it's meant to stay under). Default: enabled, 180 min.
read_keepalive_cfg() {
    python3 -c "
import json
try:    ka = json.load(open('$CFG_FILE')).get('siriusxm', {}).get('keepalive', {})
except: ka = {}
enabled = ka.get('enabled', True)
try:    mins = int(ka.get('intervalMinutes', 180))
except (TypeError, ValueError): mins = 180
mins = max(15, min(230, mins))
print(('True' if enabled else 'False') + '\t' + str(mins * 60))
" 2>/dev/null || printf 'True\t10800'
}

# Epoch seconds the current SiriusXM session started (written by the backend,
# scripts/backends/siriusxm_aiosxm.sh, on every start/re-tune). Empty/0 if not
# available - then we skip, rather than re-tune on a bad reading.
sxm_started_at() {
    python3 -c "
import json
try:    print(int(json.load(open('${STATE_DIR}/sxm_active.json')).get('startedAt', 0)))
except: print(0)
" 2>/dev/null || echo 0
}

# Atomic self-exclusion - same rationale as er_customstream_watchdog.sh: two
# Start/switch paths ensuring this watchdog close together could both find no
# live pid and both launch, orphaning one past every future Stop. Only the
# instance that gets the lock continues; any other exits at once.
LOCK_FILE="${STATE_DIR}/sxm_keepalive.lock"
exec 9>"$LOCK_FILE" || { log "ERROR: could not open lock file $LOCK_FILE"; exit 1; }
if ! flock -n 9; then
    log "Another SiriusXM keepalive watchdog instance already holds the lock - exiting (pid=$$)"
    exit 0
fi

log "SiriusXM keepalive watchdog starting (pid=$$)"
while true; do
    sleep "$POLL_SECONDS"

    IFS=$'\t' read -r ENABLED INTERVAL_SECONDS < <(read_keepalive_cfg)
    [[ "$ENABLED" != "True" ]] && continue

    [[ "$(er_active_source)" == "siriusxm" ]] || continue

    STARTED="$(sxm_started_at)"
    [[ -z "$STARTED" || "$STARTED" -le 0 ]] && continue

    NOW="$(date +%s)"
    ELAPSED=$(( NOW - STARTED ))
    (( ELAPSED < INTERVAL_SECONDS )) && continue

    log "Re-tuning SiriusXM to reset its idle timer (played ${ELAPSED}s >= ${INTERVAL_SECONDS}s threshold)"
    bash "${HERE}/er_stop_playback.sh"
    sleep 1
    if bash "${HERE}/er_start_source.sh" siriusxm; then
        log "SiriusXM re-tuned - idle timer reset"
    else
        # Couldn't restart (transient login/network hiccup). Leave active.json
        # as er_start_source left it; next poll will see no active siriusxm
        # session and stop trying until playback is back. Fallback (if the
        # operator enabled it) owns real recovery, not this.
        log "WARNING: SiriusXM re-tune failed to restart playback - see earlier log lines"
    fi
done
