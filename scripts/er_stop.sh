#!/usr/bin/env bash
# Encore Radio - Stop everything: playback, relay, backend, announcement
# scheduler, and the Rotation/Fallback watchdog. Safe to call even if
# nothing is running (best-effort).

set -uo pipefail

STATE_DIR="/home/fpp/media/plugins/fpp-EncoreRadio/state"
LOG_FILE="${MEDIADIR:-/home/fpp/media}/logs/plugin-fpp-EncoreRadio.log"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [er_stop] $*" >> "$LOG_FILE"; }

log "Stop requested"

# Header status indicator marker (see api.php / er_start_source.sh) -
# remove first so the top-bar icon disappears immediately, even if
# something below this point fails. er_stop_playback.sh also removes it,
# but this is intentionally redundant/first for that reason.
rm -f "${STATE_DIR}/active.json"

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
kill_pid_file() {
    local pid_file="$1"
    if [[ -f "$pid_file" ]]; then
        local pid
        pid="$(cat "$pid_file" 2>/dev/null)"
        if [[ -n "$pid" ]]; then
            kill "$pid" 2>/dev/null || true
            sleep 0.5
            kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$pid_file"
    fi
}
kill_pid_file "${STATE_DIR}/announce_scheduler.pid"
kill_pid_file "${STATE_DIR}/playback_scheduler.pid"

# Playback (relay, backend process, network share mount, Spotify
# pause+usage finalize) - shared with the Rotation/Fallback watchdog, see
# er_stop_playback.sh for why it's a separate script.
bash "${HERE}/er_stop_playback.sh"

log "Stop complete"
