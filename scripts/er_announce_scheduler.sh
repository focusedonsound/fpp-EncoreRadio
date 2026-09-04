#!/usr/bin/env bash
# Encore Radio - Announcement Assistant scheduler.
#
# Instead of the owner manually adding N separate FPP schedule entries to
# fire Announcement Assistant's "Play" command throughout the night, this
# loop does it for them: started alongside Encore Radio's own playback,
# stopped alongside it. AA itself is untouched - this only ever calls its
# existing "Announcement Assistant - Play" FPP Command.
#
# Two modes (config.announce.mode):
#   cadence - fire every N minutes, starting N minutes after this loop begins
#   times   - fire at specific HH:MM times (24h, local time), once per day
#
# Runs as a simple foreground loop; the caller (er_cmd_start.sh) backgrounds
# it with nohup/& and records the PID for er_stop.sh to kill.

set -uo pipefail

CFG_FILE="/home/fpp/media/config/encoreradio.json"
LOG_FILE="${MEDIADIR:-/home/fpp/media}/logs/plugin-fpp-EncoreRadio.log"
STATE_DIR="/home/fpp/media/plugins/fpp-EncoreRadio/state"
SELF_DUCK_PCT=25

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [announce] $*" >> "$LOG_FILE"; }

# On FPP 9.x, AA's ducking (aa_duck_overlay_pulse.sh) enumerates every active
# PulseAudio sink-input generically, so it reaches our stream automatically.
# On FPP 10.x, AA's ducking (aa_duck_overlay_pipewire.sh) instead calls
# "Set Slot Volume" on FPP's own Stream Slot 1 - confirmed on real hardware
# that this does NOT touch our stream at all (we never occupy a Stream Slot;
# our sink-input volume stayed at 100% for the full duration of a real AA
# Play call). So on 10.x we have to duck ourselves around the call instead.
fpp10_stream_slots_active() {
    local code
    # No "|| echo 000" fallback here: curl's -w already prints "000" on
    # its own for a connection failure (confirmed on real hardware - the
    # fallback was firing too, on top of curl's own "000", concatenating
    # into a bogus "000000" with no error ever being visible as such).
    code="$(curl -s -m 3 -o /dev/null -w '%{http_code}' \
        "http://localhost/api/command/Media%20Slot%20Status" 2>/dev/null)"
    [[ "$code" == "200" ]]
}

our_sink_input_index() {
    local pid
    pid="$(cat "${STATE_DIR}/playback.pid" 2>/dev/null || echo "")"
    if [[ -n "$pid" ]]; then
        # TuneIn/Pandora: our own ffplay process, matched by PID.
        pactl -f json list sink-inputs 2>/dev/null | python3 -c "
import json, sys
try:
    for si in json.load(sys.stdin):
        if str(si.get('properties', {}).get('application.process.id', '')) == '$pid':
            print(si['index'])
            break
except Exception:
    pass
" 2>/dev/null
        return
    fi

    # Spotify: no PID we control (Raspotify is a permanent system service),
    # so match its sink-input by application name instead. Unverified on
    # real hardware (no Spotify Premium account to test with yet) - if
    # Raspotify reports a different application.name, this lookup silently
    # finds nothing and self-ducking is skipped, same as any other
    # not-found case; check EncoreRadio.log's "self-ducking" lines against
    # `pactl list sink-inputs` if announcements don't duck Spotify on 10.x.
    pactl -f json list sink-inputs 2>/dev/null | python3 -c "
import json, sys
try:
    for si in json.load(sys.stdin):
        name = str(si.get('properties', {}).get('application.name', '')).lower()
        if 'librespot' in name or 'raspotify' in name:
            print(si['index'])
            break
except Exception:
    pass
" 2>/dev/null
}

set_our_volume() {
    local pct="$1"
    local idx
    idx="$(our_sink_input_index)"
    [[ -z "$idx" ]] && return
    pactl set-sink-input-volume "$idx" "${pct}%" 2>/dev/null || true
}

cfg_json() {
    python3 -c "
import json
try:
    print(json.dumps(json.load(open('$CFG_FILE')).get('announce', {})))
except Exception:
    print('{}')
" 2>/dev/null || echo "{}"
}

fire_announcement() {
    local slot="$1"
    local self_ducked=no

    if fpp10_stream_slots_active; then
        log "FPP 10.x detected - self-ducking our stream to ${SELF_DUCK_PCT}% (AA's own duck won't reach it)"
        set_our_volume "$SELF_DUCK_PCT"
        self_ducked=yes
    fi

    log "Firing Announcement Assistant slot=$slot"
    # FPP's /api/command endpoint blocks until the command finishes running,
    # not just until it starts - confirmed on real hardware, where AA's own
    # duck/play/fade-up sequence legitimately took ~4s and a 5s curl timeout
    # here logged a false "failed" warning even though AA completed fine.
    # 30s covers any reasonably long announcement clip; if a real timeout
    # ever fires it's worth investigating, not silently ignoring, so this
    # still logs a warning rather than swallowing curl's exit code. Because
    # the call blocks until AA's own fade-up finishes, restoring our volume
    # right after it returns lines up naturally with AA's announcement
    # actually being done, no separate wait/timer needed.
    curl -s -m 30 -X POST "http://localhost/api/command" \
        -H "Content-Type: application/json" \
        -d "{\"command\":\"Announcement Assistant - Play\",\"args\":[\"${slot}\"]}" \
        >> "$LOG_FILE" 2>&1 || log "WARNING: AA Play command call failed"

    if [[ "$self_ducked" == "yes" ]]; then
        local restore_vol
        restore_vol="$(python3 -c "
import json
try:    print(int(json.load(open('$CFG_FILE')).get('volume', 70)))
except: print(70)
" 2>/dev/null || echo 70)"
        set_our_volume "$restore_vol"
    fi
}

log "Announcement scheduler starting (pid=$$)"

LAST_FIRED_MINUTE=""

while true; do
    ANNOUNCE_JSON="$(cfg_json)"
    ENABLED="$(echo "$ANNOUNCE_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('enabled', False))" 2>/dev/null || echo False)"
    SLOT="$(echo "$ANNOUNCE_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('slot', ''))" 2>/dev/null || echo "")"
    MODE="$(echo "$ANNOUNCE_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('mode', 'cadence'))" 2>/dev/null || echo "cadence")"

    if [[ "$ENABLED" != "True" || -z "$SLOT" ]]; then
        sleep 60
        continue
    fi

    if [[ "$MODE" == "times" ]]; then
        NOW_HHMM="$(date '+%H:%M')"
        MATCH="$(echo "$ANNOUNCE_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
times = d.get('times', [])
print('yes' if '$NOW_HHMM' in times else 'no')
" 2>/dev/null || echo "no")"

        if [[ "$MATCH" == "yes" && "$LAST_FIRED_MINUTE" != "$NOW_HHMM" ]]; then
            fire_announcement "$SLOT"
            LAST_FIRED_MINUTE="$NOW_HHMM"
        fi
        sleep 55
    else
        CADENCE_MIN="$(echo "$ANNOUNCE_JSON" | python3 -c "import json,sys; print(int(json.load(sys.stdin).get('cadenceMinutes', 15)))" 2>/dev/null || echo 15)"
        [[ "$CADENCE_MIN" -lt 1 ]] && CADENCE_MIN=1
        sleep "$((CADENCE_MIN * 60))"
        # Re-check enabled/slot after sleeping in case they changed or
        # Stop was called mid-wait (er_stop.sh kills this process outright,
        # but re-checking here keeps behavior sane if it's ever re-used
        # as a long-running loop instead of being killed).
        fire_announcement "$SLOT"
    fi
done
