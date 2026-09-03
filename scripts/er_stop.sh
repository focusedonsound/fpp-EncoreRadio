#!/usr/bin/env bash
# Encore Radio - Stop everything: playback, relay, and whichever backend
# is running. Safe to call even if nothing is running (best-effort).

set -uo pipefail

STATE_DIR="/home/fpp/media/plugins/fpp-EncoreRadio/state"
LOG_FILE="/home/fpp/media/logs/EncoreRadio.log"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [er_stop] $*" >> "$LOG_FILE"; }

log "Stop requested"

# Announcement scheduler loop - stop it before touching audio, otherwise a
# cadence tick landing mid-teardown could fire AA against a slot that's
# about to have nothing left to duck.
#
# Plain SIGTERM is not reliable here: confirmed on real hardware that a
# scheduler blocked in its `sleep` builtin/external command survived
# multiple plain `kill` calls indefinitely (bash defers signal handling
# until the foreground child returns, and evidently never acted on it
# afterwards either) - same reason er_relay.sh already falls back to -9,
# applied here too.
if [[ -f "${STATE_DIR}/announce_scheduler.pid" ]]; then
    sched_pid="$(cat "${STATE_DIR}/announce_scheduler.pid" 2>/dev/null)"
    if [[ -n "$sched_pid" ]]; then
        kill "$sched_pid" 2>/dev/null || true
        sleep 0.5
        kill -9 "$sched_pid" 2>/dev/null || true
    fi
    rm -f "${STATE_DIR}/announce_scheduler.pid"
fi

# FPP 10.x playback: stop whatever slot we recorded.
if [[ -f "${STATE_DIR}/stream_slot" ]]; then
    SLOT="$(cat "${STATE_DIR}/stream_slot" 2>/dev/null || echo 1)"
    curl -s -m 5 -X POST "http://localhost/api/command" \
        -H "Content-Type: application/json" \
        -d "{\"command\":\"Stop Media Slot\",\"args\":[\"${SLOT}\"]}" \
        >> "$LOG_FILE" 2>&1 || true
    rm -f "${STATE_DIR}/stream_slot"
fi

# FPP 9.x playback: kill ffplay.
if [[ -f "${STATE_DIR}/playback.pid" ]]; then
    kill "$(cat "${STATE_DIR}/playback.pid" 2>/dev/null)" 2>/dev/null || true
    rm -f "${STATE_DIR}/playback.pid"
fi

# Pianobar: ask nicely via its control fifo, then fall back to kill.
if [[ -f "${STATE_DIR}/pianobar.pid" ]]; then
    if [[ -p "${STATE_DIR}/pianobar.fifo" ]]; then
        echo "q" > "${STATE_DIR}/pianobar.fifo" 2>/dev/null || true
        sleep 1
    fi
    kill "$(cat "${STATE_DIR}/pianobar.pid" 2>/dev/null)" 2>/dev/null || true
    rm -f "${STATE_DIR}/pianobar.pid"
fi

# Relay: always stop last, once nothing should be feeding it anymore.
"${HERE}/er_relay.sh" stop >/dev/null 2>&1 || true

log "Stop complete"
