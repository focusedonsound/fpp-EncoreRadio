#!/bin/bash
# FPP Command: Encore Radio - Play Station
#
# Plays one named Internet Radio station ($1, from the Saved Stations
# list) - meant for FPP's Scheduler, e.g. one station during the day and
# another at night. If something is already playing it's torn down first
# (playback only - the announcement scheduler and watchdogs keep running,
# same as a Rotation/Fallback swap), then the normal Start path takes it
# from there with the station forced.

set -uo pipefail

CFG_FILE="/home/fpp/media/plugindata/fpp-EncoreRadio/encoreradio.json"
STATE_DIR="/home/fpp/media/plugins/fpp-EncoreRadio/state"
LOG_FILE="${MEDIADIR:-/home/fpp/media}/logs/plugin-fpp-EncoreRadio.log"
PLUGIN_DIR="$(dirname "$(dirname "$0")")"
HERE="${PLUGIN_DIR}/scripts"

# shellcheck source=../scripts/lib_playback_schedule.sh
source "${HERE}/lib_playback_schedule.sh"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [fpp-cmd-play-station] $*" >> "$LOG_FILE"; }

STATION="${1:-}"
if [[ -z "$STATION" ]]; then
    log "ERROR: no station name given"
    exit 1
fi

log "Play Station requested: '$STATION'"

# Check the name before tearing anything down - a typo'd or since-deleted
# station shouldn't silence whatever is already playing.
if [[ -z "$(er_find_customstream_station "$STATION")" ]]; then
    log "ERROR: no Internet Radio station named '$STATION' (check Saved Stations on the Encore Radio page) - leaving current playback alone"
    exit 1
fi

if [[ -f "${STATE_DIR}/active.json" ]]; then
    bash "${PLUGIN_DIR}/scripts/er_stop_playback.sh"
    sleep 1
fi

exec bash "${PLUGIN_DIR}/commands/er_cmd_start.sh" "$STATION"
