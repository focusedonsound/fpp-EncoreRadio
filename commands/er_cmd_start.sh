#!/bin/bash
# FPP Command: Encore Radio - Start
#
# Picks the source to play - normally just config's flat "source" field,
# but Rotation (premium) can pick something different for right now on a
# schedule, and Fallback (premium) walks a chain of sources if the first
# choice fails to start - then starts it via er_start_source.sh, starts
# the announcement scheduler, and (if Rotation/Fallback are enabled) the
# playback_scheduler.sh watchdog that keeps re-checking afterward.

set -uo pipefail

CFG_FILE="/home/fpp/media/config/encoreradio.json"
LOG_FILE="${MEDIADIR:-/home/fpp/media}/logs/plugin-fpp-EncoreRadio.log"
STATE_DIR="/home/fpp/media/plugins/fpp-EncoreRadio/state"
PLUGIN_DIR="$(dirname "$(dirname "$0")")"
HERE="${PLUGIN_DIR}/scripts"
mkdir -p "$STATE_DIR" 2>/dev/null || true

# shellcheck source=../scripts/lib_playback_schedule.sh
source "${HERE}/lib_playback_schedule.sh"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [fpp-cmd-start] $*" >> "$LOG_FILE"; }

if [[ ! -f "$CFG_FILE" ]]; then
    log "ERROR: config not found: $CFG_FILE"
    exit 1
fi

CONFIGURED_SOURCE="$(python3 -c "
import json
try:    print(json.load(open('$CFG_FILE')).get('source', ''))
except: print('')
" 2>/dev/null || echo "")"

ROT_ON="$(er_feature_enabled rotation)"
FB_ON="$(er_feature_enabled fallback)"
ROTATION_OR_FALLBACK_ACTIVE=0

if [[ "$ROT_ON" == "True" || "$FB_ON" == "True" ]]; then
    GATE_MSG="$(bash "${HERE}/er_premium_gate.sh" check)" && GATE_RC=0 || GATE_RC=$?
    if [[ "$GATE_RC" -eq 0 ]]; then
        ROTATION_OR_FALLBACK_ACTIVE=1
    else
        log "Rotation/Fallback configured but not usable right now: $GATE_MSG - using configured source only"
    fi
fi

INITIAL_SOURCE="$CONFIGURED_SOURCE"
if [[ "$ROTATION_OR_FALLBACK_ACTIVE" -eq 1 && "$ROT_ON" == "True" ]]; then
    ROTATION_PICK="$(er_rotation_target)"
    if [[ -n "$ROTATION_PICK" ]]; then
        INITIAL_SOURCE="$ROTATION_PICK"
        log "Rotation: schedule picks '$ROTATION_PICK' for right now"
    else
        log "Rotation: no schedule entry matches right now - using configured source"
    fi
fi

if [[ -z "$INITIAL_SOURCE" ]]; then
    log "ERROR: no source configured (encoreradio.json 'source' is empty, and no Rotation entry matches right now)"
    exit 1
fi

log "START source=$INITIAL_SOURCE"

if bash "${HERE}/er_start_source.sh" "$INITIAL_SOURCE"; then
    STARTED_SOURCE="$INITIAL_SOURCE"
elif [[ "$ROTATION_OR_FALLBACK_ACTIVE" -eq 1 && "$FB_ON" == "True" ]]; then
    log "$INITIAL_SOURCE failed to start - trying Fallback chain"
    STARTED_SOURCE=""
    TRY="$INITIAL_SOURCE"
    while :; do
        TRY="$(er_next_fallback_target "$TRY")"
        [[ -z "$TRY" ]] && break
        log "Fallback: trying $TRY"
        if bash "${HERE}/er_start_source.sh" "$TRY"; then
            STARTED_SOURCE="$TRY"
            break
        fi
    done
    if [[ -z "$STARTED_SOURCE" ]]; then
        log "ERROR: every source in the Fallback chain failed to start"
        exit 1
    fi
else
    log "ERROR: $INITIAL_SOURCE failed to start (Fallback not enabled)"
    exit 1
fi

log "Playing: $STARTED_SOURCE"

ANNOUNCE_PID_FILE="${STATE_DIR}/announce_scheduler.pid"
if [[ -f "$ANNOUNCE_PID_FILE" ]] && kill -0 "$(cat "$ANNOUNCE_PID_FILE" 2>/dev/null)" 2>/dev/null; then
    log "Announcement scheduler already running, leaving it be"
else
    nohup bash "${HERE}/er_announce_scheduler.sh" >> "$LOG_FILE" 2>&1 &
    echo $! > "$ANNOUNCE_PID_FILE"
    log "Announcement scheduler started pid=$(cat "$ANNOUNCE_PID_FILE")"
fi

PLAYBACK_SCHED_PID_FILE="${STATE_DIR}/playback_scheduler.pid"
if [[ "$ROTATION_OR_FALLBACK_ACTIVE" -eq 1 ]]; then
    if [[ -f "$PLAYBACK_SCHED_PID_FILE" ]] && kill -0 "$(cat "$PLAYBACK_SCHED_PID_FILE" 2>/dev/null)" 2>/dev/null; then
        log "Playback scheduler already running, leaving it be"
    else
        nohup bash "${HERE}/er_playback_scheduler.sh" >> "$LOG_FILE" 2>&1 &
        echo $! > "$PLAYBACK_SCHED_PID_FILE"
        log "Playback scheduler started pid=$(cat "$PLAYBACK_SCHED_PID_FILE")"
    fi
fi
