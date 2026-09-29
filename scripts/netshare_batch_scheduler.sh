#!/usr/bin/env bash
# Encore Radio - Network Share rolling-batch scheduler.
#
# Fetches and plays the Network Share source in small batches, via
# smbclient, so an arbitrarily large remote library never needs to fit on
# local storage (see netshare_folder.sh, which launches this as a
# background daemon after the one-time remote enumeration).
#
# Design: walk a shuffled pass through the full enumerated file list
# (netshare_remote_list.txt), BATCH_SIZE tracks at a time. Each batch is
# staged to its own local directory and played through the same
# relay/concat mechanism every other multi-file source uses, then
# deleted once played. The NEXT batch is prefetched while the current one
# plays, so advancing to it costs only the same relay-restart overhead
# every source switch already has - not a fetch wait - except for the
# very first batch, which netshare_folder.sh waits on synchronously.
#
# A relay restart between batches drops the downstream ffplay's
# connection (it's `ffmpeg -listen 1`, exactly one connection for that
# process's lifetime - see er_start_source.sh), so unlike every other
# source (started once, plays forever), THIS script has to re-trigger
# er_play_pulse.sh itself at every batch boundary after the first - the
# first batch is handled by the normal outer flow (er_start_source.sh's
# wait_for_relay + er_play_pulse.sh, run by netshare_folder.sh's caller),
# and calling er_play_pulse.sh again here for that same first batch would
# start a second, duplicate ffplay.
#
# Usage: netshare_batch_scheduler.sh <sharePath>
#
# Takes only the share path, not the configured folder: every remote path
# in netshare_remote_list.txt is already relative to the share ROOT (see
# netshare_folder.sh - smbclient's recursive `ls` prints paths that way
# even when scoped to a folder via -D), so nothing here needs the folder
# separately.

set -uo pipefail

SHARE_PATH="${1:?}"

CFG_FILE="/home/fpp/media/plugindata/fpp-EncoreRadio/encoreradio.json"
CFG_DIR="$(dirname "$CFG_FILE")"
AUTH_FILE="${CFG_DIR}/netshare_authfile"
STATE_DIR="/home/fpp/media/plugins/fpp-EncoreRadio/state"
LOG_FILE="${MEDIADIR:-/home/fpp/media}/logs/plugin-fpp-EncoreRadio.log"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REMOTE_LIST_FILE="${STATE_DIR}/netshare_remote_list.txt"
STAGE_ROOT="${STATE_DIR}/netshare_stage"
SCHEDULER_PID_FILE="${STATE_DIR}/netshare_scheduler.pid"

# Small enough that a batch fetches in a few seconds on a typical LAN
# (this process's own startup, staging batch 1, is on netshare_folder.sh's
# synchronous critical path - see its own ~50s cap waiting on the relay to
# start), large enough that a batch's play-through comfortably outlasts
# the time it takes to prefetch the next one.
BATCH_SIZE=5

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [netshare-batch] $*" >> "$LOG_FILE"; }

cleanup() {
    rm -rf "$STAGE_ROOT" 2>/dev/null || true
    rm -f "$AUTH_FILE" 2>/dev/null || true
}
trap cleanup EXIT

# Still running as the scheduler this PID file names? If not, we've been
# superseded by a fresh netshare_folder.sh (re-Start with new config) or
# killed by Stop and something else already owns cleanup - either way,
# exit without touching state a newer/other process may already own.
is_current_scheduler() {
    [[ -f "$SCHEDULER_PID_FILE" ]] && [[ "$(cat "$SCHEDULER_PID_FILE" 2>/dev/null)" == "$$" ]]
}

relay_port() {
    python3 -c "
import json
try:    print(int(json.load(open('$CFG_FILE')).get('relay', {}).get('port', 8123)))
except: print(8123)
" 2>/dev/null || echo 8123
}

# Same reasoning as er_start_source.sh's wait_for_relay: poll for the
# relay's port actually in LISTEN state (never connect-and-close to test
# it - that would itself consume the -listen 1 socket's one accept slot).
wait_for_relay_port() {
    local port tries=40
    port="$(relay_port)"
    if ! command -v ss >/dev/null 2>&1; then
        sleep 3
        return 0
    fi
    for ((i = 0; i < tries; i++)); do
        ss -ltn "sport = :${port}" 2>/dev/null | grep -q LISTEN && return 0
        sleep 0.25
    done
    return 1
}

mkdir -p "$STAGE_ROOT"

mapfile -d '' -t ALL_FILES < "$REMOTE_LIST_FILE"
TOTAL="${#ALL_FILES[@]}"
if [[ "$TOTAL" -eq 0 ]]; then
    log "ERROR: no files in remote list - nothing to play"
    exit 1
fi

SHUFFLED=()
CURSOR=0
reshuffle() {
    mapfile -d '' -t SHUFFLED < <(printf '%s\0' "${ALL_FILES[@]}" | shuf -z)
    CURSOR=0
    log "Reshuffled ${TOTAL} tracks for a fresh pass"
}
reshuffle

# Fetches up to BATCH_SIZE tracks (wrapping/reshuffling the walk as
# needed) into a fresh numbered staging directory and writes its
# playlist.concat for er_relay.sh's "playlist" mode. A track that fails
# to fetch is skipped, not fatal - one bad/renamed file on the share
# shouldn't stop the whole station. Sets STAGE_RESULT_DIR and returns 0 on
# success (at least one track staged); returns 1 (STAGE_RESULT_DIR
# unset/stale) if every attempt in this batch failed.
#
# Deliberately called as a plain statement (`stage_batch`), never via
# `$(stage_batch)` - command substitution runs the function in a subshell,
# and BATCH_N/CURSOR/SHUFFLED are mutated INSIDE this function and must
# persist across calls (each call has to pick up where the last one left
# off in the shuffled walk, and use a new batch directory each time).
# Confirmed on real hardware: with command substitution, every call
# reverted to the parent's stale copies of those variables, so every
# batch resolved to the same directory name and CURSOR restarted at 0 -
# the prefetched "next" batch's fetch loop overwrote the currently-playing
# batch's own files and playlist out from under ffmpeg while it was
# reading them (ffmpeg: "Invalid data found when processing input").
BATCH_N=0
STAGE_RESULT_DIR=""
stage_batch() {
    BATCH_N=$((BATCH_N + 1))
    local dir="${STAGE_ROOT}/batch${BATCH_N}"
    mkdir -p "$dir"
    local playlist="${dir}/playlist.concat"
    : > "$playlist"

    local staged=0 attempts=0
    while [[ "$staged" -lt "$BATCH_SIZE" && "$attempts" -lt $((BATCH_SIZE * 3)) ]]; do
        attempts=$((attempts + 1))
        if [[ "$CURSOR" -ge "$TOTAL" ]]; then
            reshuffle
        fi
        local remote="${SHUFFLED[$CURSOR]}"
        CURSOR=$((CURSOR + 1))
        local local_path
        local_path="${dir}/$(printf '%04d' "$staged").audio"

        # No -D here: smbclient's recursive `ls` (netshare_folder.sh) prints
        # each header path relative to the SHARE ROOT even when scoped with
        # -D to a folder, so $remote already has that folder prefix baked
        # in - adding -D "$FOLDER" again here would look it up twice
        # (confirmed on real hardware: NT_STATUS_OBJECT_PATH_NOT_FOUND on
        # "<folder>\<folder>\...\track.mp3" until this was removed).
        if smbclient "$SHARE_PATH" -A "$AUTH_FILE" \
            -c "get \"${remote}\" \"${local_path}\"" >>"$LOG_FILE" 2>&1 \
            && [[ -s "$local_path" ]]; then
            local escaped="${local_path//\'/\'\\\'\'}"
            echo "file '${escaped}'" >> "$playlist"
            staged=$((staged + 1))
        else
            log "WARNING: failed to fetch '${remote}' - skipping"
            rm -f "$local_path" 2>/dev/null || true
        fi
    done

    if [[ "$staged" -eq 0 ]]; then
        rm -rf "$dir" 2>/dev/null || true
        STAGE_RESULT_DIR=""
        return 1
    fi
    log "Staged batch ${BATCH_N}: ${staged}/${BATCH_SIZE} tracks"
    STAGE_RESULT_DIR="$dir"
    return 0
}

stage_batch || { log "ERROR: could not stage an initial batch"; exit 1; }
CURRENT_DIR="$STAGE_RESULT_DIR"
"${HERE}/er_relay.sh" start playlist "${CURRENT_DIR}/playlist.concat"
# Batch 1 only: the caller (netshare_folder.sh -> er_start_source.sh)
# handles wait_for_relay + er_play_pulse.sh itself for this first relay -
# do not duplicate that here.

stage_batch && NEXT_DIR="$STAGE_RESULT_DIR" || NEXT_DIR=""

while true; do
    if [[ -f "${STATE_DIR}/relay.pid" ]]; then
        RELAY_PID="$(cat "${STATE_DIR}/relay.pid" 2>/dev/null || echo "")"
        while [[ -n "$RELAY_PID" ]] && kill -0 "$RELAY_PID" 2>/dev/null; do
            sleep 1
            is_current_scheduler || exit 0
        done
    else
        sleep 1
    fi

    # Being superseded/stopped is the normal way this loop ends - a dead
    # relay only means "advance to the next batch" while we're still the
    # scheduler of record.
    is_current_scheduler || exit 0

    rm -rf "$CURRENT_DIR" 2>/dev/null || true

    if [[ -z "$NEXT_DIR" ]]; then
        # Prefetch itself failed (e.g. share briefly unreachable) - retry
        # inline rather than giving up the station entirely.
        log "No prefetched batch ready - retrying in 10s"
        sleep 10
        stage_batch && NEXT_DIR="$STAGE_RESULT_DIR" || NEXT_DIR=""
        continue
    fi

    CURRENT_DIR="$NEXT_DIR"
    NEXT_DIR=""
    log "Advancing to batch: ${CURRENT_DIR}"
    "${HERE}/er_relay.sh" start playlist "${CURRENT_DIR}/playlist.concat"

    if wait_for_relay_port; then
        bash "${HERE}/er_play_pulse.sh"
    else
        log "ERROR: relay never opened its port for batch ${CURRENT_DIR} - playback silent until the next batch"
    fi

    stage_batch && NEXT_DIR="$STAGE_RESULT_DIR" || NEXT_DIR=""
done
