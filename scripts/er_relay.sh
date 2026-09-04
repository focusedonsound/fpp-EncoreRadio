#!/usr/bin/env bash
# Encore Radio - local relay.
#
# Every backend (TuneIn, Pandora, later Spotify) converges on one thing:
# a local HTTP stream at http://127.0.0.1:<port>/stream that either
# playback path (FPP 10.x "Play Media" / FPP 9.x ffplay-into-Pulse) can
# point at. This script owns that relay process.
#
# Usage:
#   er_relay.sh start url <source-stream-url>
#   er_relay.sh start pulse-source <pulse-source-name>   # e.g. a monitor source
#   er_relay.sh start playlist <ffmpeg-concat-file>      # local files, looped forever
#   er_relay.sh stop
#   er_relay.sh status

set -euo pipefail

CFG_DIR="/home/fpp/media/config"
CFG_FILE="${CFG_DIR}/encoreradio.json"
STATE_DIR="/home/fpp/media/plugins/fpp-EncoreRadio/state"
LOG_FILE="/home/fpp/media/logs/EncoreRadio.log"
PID_FILE="${STATE_DIR}/relay.pid"

mkdir -p "$STATE_DIR" 2>/dev/null || true

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [er_relay] $*" >> "$LOG_FILE"; }

relay_port() {
    if [[ -f "$CFG_FILE" ]]; then
        python3 -c "
import json
try:    print(int(json.load(open('$CFG_FILE')).get('relay', {}).get('port', 8123)))
except: print(8123)
" 2>/dev/null || echo 8123
    else
        echo 8123
    fi
}

is_running() {
    [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null
}

do_stop() {
    if is_running; then
        local pid
        pid="$(cat "$PID_FILE")"
        log "STOP relay pid=$pid"
        kill "$pid" 2>/dev/null || true
        sleep 0.5
        kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
}

do_start() {
    local mode="$1" src="$2"
    local port
    port="$(relay_port)"

    do_stop

    local input_args=()
    case "$mode" in
        url)
            # -re paces input at native playback rate; without it ffmpeg
            # would read the source as fast as possible instead of streaming.
            input_args=(-re -i "$src")
            ;;
        pulse-source)
            input_args=(-f pulse -i "$src")
            ;;
        playlist)
            # No -stream_loop here - confirmed on real hardware that
            # ffmpeg's -stream_loop doesn't reliably loop the concat
            # demuxer back to the start (it plays through correctly once,
            # then exits with "Operation not permitted" trying to restart
            # rather than actually looping). netshare_folder.sh works
            # around this by writing the shuffled file list into the
            # concat playlist many times over instead, so there's no
            # separate "reached the end, restart" logic needed here.
            input_args=(-re -f concat -safe 0 -i "$src")
            ;;
        *)
            log "ERROR: unknown relay mode: $mode"
            exit 2
            ;;
    esac

    log "START relay mode=$mode src=$src port=$port"
    nohup ffmpeg -hide_banner -loglevel warning \
        "${input_args[@]}" \
        -vn -acodec libmp3lame -b:a 128k -content_type audio/mpeg \
        -f mp3 -listen 1 "http://0.0.0.0:${port}/stream" \
        >> "$LOG_FILE" 2>&1 &
    local relay_pid=$!

    # If we can't record the PID, we can't stop it later either - kill it
    # now rather than leaving an orphaned ffmpeg holding the port forever
    # (found on real hardware: a failed write here left a process bound to
    # :8123 that no later Start/Stop could ever find or kill again).
    if ! echo "$relay_pid" > "$PID_FILE" 2>/dev/null; then
        log "ERROR: could not write $PID_FILE - killing untracked relay pid=$relay_pid"
        kill "$relay_pid" 2>/dev/null || true
        exit 1
    fi
    log "Relay started pid=$relay_pid"
}

case "${1:-}" in
    start)
        do_start "${2:-}" "${3:-}"
        ;;
    stop)
        do_stop
        ;;
    status)
        if is_running; then
            echo "running pid=$(cat "$PID_FILE") port=$(relay_port)"
        else
            echo "stopped"
        fi
        ;;
    *)
        echo "Usage: $0 {start url <url>|start pulse-source <name>|start playlist <concat-file>|stop|status}" >&2
        exit 1
        ;;
esac
