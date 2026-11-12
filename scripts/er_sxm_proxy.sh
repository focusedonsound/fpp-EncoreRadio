#!/usr/bin/env bash
# Encore Radio - SiriusXM (aiosxm) proxy lifecycle controller.
#
# SiriusXM has no headless Linux client in the shape librespot (Spotify) or
# pianobar (Pandora) provide. aiosxm (https://github.com/MizterB/aiosxm) is a
# small Python asyncio service that logs in with the subscriber's own
# credentials and re-serves each channel as a plain AES-128 HLS playlist on a
# loopback HTTP port - the SAME "hand the relay a URL" shape TuneIn already
# uses (ffmpeg decrypts standard HLS natively). So unlike Pandora, this needs
# no PulseAudio null-sink capture: start this proxy, then point er_relay.sh at
# its /stream/.../playlist.m3u8 URL.
#
# aiosxm requires Python >= 3.12 and is installed into a dedicated venv by
# fpp_install.sh (system python3 on a current FPP 10.x/Trixie box, or a
# uv-provisioned standalone 3.12 on older boxes). This script only ever runs
# the venv's own aiosxm-proxy entry point - it never installs anything.
#
# The proxy binds 127.0.0.1 ONLY. It has no auth of its own and sets
# Access-Control-Allow-Origin: * - binding anything but loopback would expose
# an unauthenticated SiriusXM session to the LAN.
#
# Usage:
#   er_sxm_proxy.sh ensure            -> start the proxy if not already up; exit 0 when it's listening AND logged in
#   er_sxm_proxy.sh stop              -> stop the proxy
#   er_sxm_proxy.sh status            -> "running pid=.. port=.." or "stopped"
#   er_sxm_proxy.sh entitlements      -> ensure, then print the /entitlements JSON
#   er_sxm_proxy.sh resolve <query>   -> ensure, then print "<type>\t<id>\t<title>" for the channel matching a number or name
#   er_sxm_proxy.sh url <query>       -> ensure+resolve, then print the full playlist URL for that channel
#   er_sxm_proxy.sh channels          -> ensure, then print the raw /channels JSON (for a future picker UI)

set -uo pipefail

CFG_DIR="/home/fpp/media/plugindata/fpp-EncoreRadio"
CFG_FILE="${CFG_DIR}/encoreradio.json"
STATE_DIR="/home/fpp/media/plugins/fpp-EncoreRadio/state"
LOG_FILE="${MEDIADIR:-/home/fpp/media}/logs/plugin-fpp-EncoreRadio.log"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VENV_DIR="${CFG_DIR}/aiosxm-venv"
PROXY_BIN="${VENV_DIR}/bin/aiosxm-proxy"
PID_FILE="${STATE_DIR}/aiosxm.pid"

mkdir -p "$STATE_DIR" 2>/dev/null || true

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [sxm-proxy] $*" >> "$LOG_FILE"; }

cfg() {
    python3 -c "
import json
try:    print(json.load(open('$CFG_FILE')).get('siriusxm', {}).get('$1', ''))
except: print('')
" 2>/dev/null || echo ""
}

PROXY_PORT="$(cfg proxyPort)"
# Digits only, and a sane default - this value is spliced straight into
# curl/ffmpeg URLs below, and the relay already defaults to 8123, so the
# proxy sits one above it unless the operator changed it.
PROXY_PORT="${PROXY_PORT//[^0-9]/}"
[[ -z "$PROXY_PORT" ]] && PROXY_PORT=8124

BITRATE="$(cfg bitrate)"
# aiosxm only accepts this fixed set (const.py); the relay re-encodes to
# 128k MP3 anyway, so pulling 128k AAC upstream is the sensible default -
# no point fetching 256k just to down-convert it.
case "$BITRATE" in
    32k|64k|96k|128k|256k) : ;;
    *) BITRATE=128k ;;
esac

is_running() {
    [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null
}

port_listening() {
    if command -v ss >/dev/null 2>&1; then
        ss -ltn "sport = :${PROXY_PORT}" 2>/dev/null | grep -q LISTEN
    else
        # No ss (shouldn't happen on FPP, iproute2 is always present) - fall
        # back to a curl probe of the proxy's own root route.
        curl -s -m 2 -o /dev/null "http://127.0.0.1:${PROXY_PORT}/" 2>/dev/null
    fi
}

do_stop() {
    if is_running; then
        local pid
        pid="$(cat "$PID_FILE")"
        log "STOP aiosxm proxy pid=$pid"
        kill "$pid" 2>/dev/null || true
        sleep 0.5
        kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
}

# GET a proxy route, print the body, return curl's success/failure.
proxy_get() {
    local path="$1" tmax="${2:-10}"
    curl -s -m "$tmax" "http://127.0.0.1:${PROXY_PORT}${path}"
}

do_ensure() {
    if [[ ! -x "$PROXY_BIN" ]]; then
        log "ERROR: aiosxm not installed ($PROXY_BIN missing) - re-run the plugin install, or this box's architecture/Python is unsupported for SiriusXM."
        return 1
    fi

    local username password
    # Strip CR/LF defensively - these go into the child's environment, and a
    # newline in a credential has no legitimate purpose here.
    username="$(cfg username | tr -d '\r\n')"
    password="$(cfg password | tr -d '\r\n')"
    if [[ -z "$username" || -z "$password" ]]; then
        log "ERROR: SiriusXM username/password not configured"
        return 1
    fi

    if is_running && port_listening; then
        return 0
    fi
    # Stale pid (process gone) or a half-up proxy - clean slate.
    do_stop

    log "Starting aiosxm proxy on 127.0.0.1:${PROXY_PORT}"
    # Credentials passed via the environment, NOT --username/--password: CLI
    # flags show up in `ps` for every local user; an env var on a root-owned
    # process does not (/proc/<pid>/environ is mode 0400). aiosxm reads
    # SXM_USERNAME/SXM_PASSWORD (cli.py).
    SXM_USERNAME="$username" SXM_PASSWORD="$password" \
        nohup "$PROXY_BIN" --host 127.0.0.1 --port "$PROXY_PORT" >> "$LOG_FILE" 2>&1 &
    local pid=$!
    if ! echo "$pid" > "$PID_FILE" 2>/dev/null; then
        log "ERROR: could not write $PID_FILE - killing untracked proxy pid=$pid"
        kill "$pid" 2>/dev/null || true
        return 1
    fi

    # Wait for it to bind its port. aiosxm logs in to SiriusXM during startup
    # and exits nonzero on a bad login (AuthenticationError -> exit 1) or
    # missing creds (exit 2), so also bail the moment the process dies rather
    # than waiting out the whole timeout on a wrong password.
    local i
    for ((i = 0; i < 60; i++)); do
        if ! kill -0 "$pid" 2>/dev/null; then
            log "ERROR: aiosxm proxy exited during startup - check the SiriusXM username/password (see log above)"
            rm -f "$PID_FILE"
            return 1
        fi
        port_listening && break
        sleep 0.25
    done
    if ! port_listening; then
        log "ERROR: aiosxm proxy never opened port ${PROXY_PORT}"
        do_stop
        return 1
    fi
    log "aiosxm proxy listening on 127.0.0.1:${PROXY_PORT} (pid=$pid)"
    return 0
}

cmd_entitlements() {
    do_ensure || return 1
    proxy_get "/entitlements" 10
}

# Match the operator's free-text channel (a SiriusXM channel NUMBER, or a
# name) against /channels and print "<type>\t<id>\t<title>". Exact
# channel_number wins; otherwise a case-insensitive match on title /
# title_short (exact before substring). Prints nothing and returns 1 on no
# match - the caller logs the failure.
cmd_resolve() {
    local query="$1"
    [[ -z "$query" ]] && { log "ERROR: no SiriusXM channel configured"; return 1; }
    do_ensure || return 1

    local channels_json
    channels_json="$(proxy_get "/channels" 30)"
    if [[ -z "$channels_json" ]]; then
        log "ERROR: could not fetch channel list from aiosxm proxy"
        return 1
    fi

    # JSON piped via stdin (not interpolated into the -c string) so a channel
    # title containing quotes can never break the Python source or inject.
    QUERY="$query" python3 -c "
import json, os, sys
q = os.environ['QUERY'].strip()
ql = q.lower()
try:
    chans = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if not isinstance(chans, list):
    sys.exit(1)

def pick(c):
    return (c.get('type') or 'channel-linear', c.get('id') or '', c.get('title') or c.get('title_short') or '')

# 1) exact channel number
for c in chans:
    if str(c.get('channel_number', '')).strip() == q:
        t, i, title = pick(c)
        if i:
            print(f'{t}\t{i}\t{title}'); sys.exit(0)
# 2) exact title / title_short (case-insensitive)
for c in chans:
    for key in ('title', 'title_short'):
        if (c.get(key) or '').strip().lower() == ql:
            t, i, title = pick(c)
            if i:
                print(f'{t}\t{i}\t{title}'); sys.exit(0)
# 3) substring on title / title_short
for c in chans:
    for key in ('title', 'title_short'):
        if ql and ql in (c.get(key) or '').lower():
            t, i, title = pick(c)
            if i:
                print(f'{t}\t{i}\t{title}'); sys.exit(0)
sys.exit(1)
" <<< "$channels_json" 2>/dev/null
    return $?
}

cmd_url() {
    local query="$1" line type id
    line="$(cmd_resolve "$query")" || return 1
    type="$(printf '%s' "$line" | cut -f1)"
    id="$(printf '%s' "$line" | cut -f2)"
    [[ -z "$type" || -z "$id" ]] && return 1
    printf 'http://127.0.0.1:%s/stream/%s/%s/playlist.m3u8?bitrate=%s\n' \
        "$PROXY_PORT" "$type" "$id" "$BITRATE"
}

cmd_channels() {
    do_ensure || return 1
    proxy_get "/channels" 30
}

case "${1:-}" in
    ensure)       do_ensure ;;
    stop)         do_stop ;;
    status)       if is_running; then echo "running pid=$(cat "$PID_FILE") port=${PROXY_PORT}"; else echo "stopped"; fi ;;
    entitlements) cmd_entitlements ;;
    resolve)      cmd_resolve "${2:-}" ;;
    url)          cmd_url "${2:-}" ;;
    channels)     cmd_channels ;;
    *)
        echo "Usage: $0 {ensure|stop|status|entitlements|resolve <query>|url <query>|channels}" >&2
        exit 2
        ;;
esac
