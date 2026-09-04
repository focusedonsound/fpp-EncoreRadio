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

# Header status indicator marker (see api.php / er_cmd_start.sh) - remove
# first so the top-bar icon disappears immediately, even if something
# below this point fails.
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
if [[ -f "${STATE_DIR}/announce_scheduler.pid" ]]; then
    sched_pid="$(cat "${STATE_DIR}/announce_scheduler.pid" 2>/dev/null)"
    if [[ -n "$sched_pid" ]]; then
        kill "$sched_pid" 2>/dev/null || true
        sleep 0.5
        kill -9 "$sched_pid" 2>/dev/null || true
    fi
    rm -f "${STATE_DIR}/announce_scheduler.pid"
fi

# Playback: kill ffplay (same path on both FPP versions - see
# er_cmd_start.sh for why there's no separate Stream Slot path).
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

# Network share: unmount so a changed share/folder/credentials next time
# starts clean rather than reusing a stale mount.
NETSHARE_MOUNT="${STATE_DIR}/netshare_mount"
if mountpoint -q "$NETSHARE_MOUNT" 2>/dev/null; then
    sudo umount "$NETSHARE_MOUNT" 2>/dev/null || sudo umount -l "$NETSHARE_MOUNT" 2>/dev/null || true
fi

# Spotify: nothing local to kill (Raspotify is a permanent system service,
# not something this plugin starts/stops) - just pause playback via the
# Web API so it doesn't keep going after after-hours mode ends.
CFG_FILE="/home/fpp/media/config/encoreradio.json"
SOURCE="$(python3 -c "
import json
try:    print(json.load(open('$CFG_FILE')).get('source', ''))
except: print('')
" 2>/dev/null || echo "")"
if [[ "$SOURCE" == "spotify" ]]; then
    TOKEN="$(bash "${HERE}/spotify_token.sh" 2>/dev/null)"
    if [[ -n "$TOKEN" ]]; then
        curl -s -m 10 -X PUT "https://api.spotify.com/v1/me/player/pause" \
            -H "Authorization: Bearer ${TOKEN}" >> "$LOG_FILE" 2>&1 || true
    fi
fi

# Premium usage tracking: Pandora and Spotify are both gated (the custom
# stream and TuneIn never are), so both need their trial-hour session
# finalized here.
if [[ "$SOURCE" == "spotify" || "$SOURCE" == "pandora" ]]; then
    bash "${HERE}/er_track_usage.sh" finalize
fi

log "Stop complete"
