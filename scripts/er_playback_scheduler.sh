#!/usr/bin/env bash
# Encore Radio - Rotation/Fallback watchdog (premium).
#
# Runs alongside the announcement scheduler once Start is called, but only
# does anything when Rotation and/or Fallback are enabled in config - on a
# poll interval, it either swaps to whatever source the Rotation schedule
# says should be playing right now, or (Fallback) checks that the
# currently active source's playback is actually still alive and advances
# to the next entry in the fallback chain if it isn't.
#
# Gated the same way as Pandora/Spotify (er_premium_gate.sh) - Rotation
# and Fallback are premium capabilities in their own right, independent of
# which underlying source type they end up choosing.

set -uo pipefail

CFG_FILE="/home/fpp/media/config/encoreradio.json"
STATE_DIR="/home/fpp/media/plugins/fpp-EncoreRadio/state"
LOG_FILE="${MEDIADIR:-/home/fpp/media}/logs/plugin-fpp-EncoreRadio.log"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLL_SECONDS=30

# shellcheck source=lib_playback_schedule.sh
source "${HERE}/lib_playback_schedule.sh"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [playback-scheduler] $*" >> "$LOG_FILE"; }

switch_to() {
    log "Switching playback to: $1"
    bash "${HERE}/er_stop_playback.sh"
    sleep 1
    bash "${HERE}/er_start_source.sh" "$1"
}

log "Playback scheduler starting (pid=$$)"
while true; do
    sleep "$POLL_SECONDS"

    ROT_ON="$(er_feature_enabled rotation)"
    FB_ON="$(er_feature_enabled fallback)"
    [[ "$ROT_ON" != "True" && "$FB_ON" != "True" ]] && continue

    GATE_MSG="$(bash "${HERE}/er_premium_gate.sh" check)" && GATE_RC=0 || GATE_RC=$?
    if [[ "$GATE_RC" -ne 0 ]]; then
        log "Rotation/Fallback blocked: $GATE_MSG"
        continue
    fi

    CUR="$(er_active_source)"

    if [[ "$ROT_ON" == "True" ]]; then
        WANT="$(er_rotation_target)"
        if [[ -n "$WANT" && "$WANT" != "$CUR" ]]; then
            switch_to "$WANT"
            continue
        fi
    fi

    if [[ "$FB_ON" == "True" && -n "$CUR" ]] && ! er_playback_alive "$CUR"; then
        log "Playback for '$CUR' appears to have died - advancing fallback chain"
        NEXT="$(er_next_fallback_target "$CUR")"
        if [[ -n "$NEXT" ]]; then
            switch_to "$NEXT"
        else
            log "Fallback chain exhausted - nothing left to try"
        fi
    fi
done
