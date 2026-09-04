#!/usr/bin/env bash
# Encore Radio - Rotation/Fallback shared logic (premium).
#
# Sourced by both commands/er_cmd_start.sh (to pick the initial source at
# Start time) and er_playback_scheduler.sh (the background watchdog that
# keeps re-checking afterward) - kept in one place so the two never drift
# out of sync with each other.
#
# Requires CFG_FILE, STATE_DIR, HERE to already be set by the caller.

er_feature_enabled() {
    # $1 = "rotation" or "fallback"
    python3 -c "
import json
try:    print(json.load(open('$CFG_FILE')).get('$1', {}).get('enabled', False))
except: print(False)
" 2>/dev/null
}

# Fixed weekday index rather than strftime('%a') - avoids any locale
# dependency on what a non-English-locale system might name weekdays.
er_rotation_target() {
    python3 -c "
import json, datetime
WEEKDAYS = ['mon','tue','wed','thu','fri','sat','sun']
try:
    cfg = json.load(open('$CFG_FILE'))
except Exception:
    cfg = {}
now = datetime.datetime.now()
dow = WEEKDAYS[now.weekday()]
cur = now.strftime('%H:%M')
chosen = ''
for e in cfg.get('rotation', {}).get('entries', []):
    if dow not in (e.get('days') or []):
        continue
    st, en = e.get('startTime', ''), e.get('endTime', '')
    if not st or not en:
        continue
    # endTime <= startTime means the window wraps past midnight.
    match = (st <= cur < en) if st <= en else (cur >= st or cur < en)
    if match:
        chosen = e.get('source', '')
        break
print(chosen)
" 2>/dev/null
}

er_active_source() {
    python3 -c "
import json
try:    print(json.load(open('${STATE_DIR}/active.json')).get('source', ''))
except: print('')
" 2>/dev/null
}

er_next_fallback_target() {
    # $1 = current source ("" if none active yet)
    python3 -c "
import json
try:    cfg = json.load(open('$CFG_FILE'))
except: cfg = {}
chain = cfg.get('fallback', {}).get('chain', [])
cur = '$1'
try:    idx = chain.index(cur)
except ValueError: idx = -1
rest = chain[idx + 1:] if idx >= 0 else chain
print(rest[0] if rest else '')
" 2>/dev/null
}

er_playback_alive() {
    case "$1" in
        customstream|netshare|tunein)
            [[ -f "${STATE_DIR}/playback.pid" ]] && kill -0 "$(cat "${STATE_DIR}/playback.pid" 2>/dev/null)" 2>/dev/null
            ;;
        pandora)
            [[ -f "${STATE_DIR}/pianobar.pid" ]] && kill -0 "$(cat "${STATE_DIR}/pianobar.pid" 2>/dev/null)" 2>/dev/null \
                && [[ -f "${STATE_DIR}/playback.pid" ]] && kill -0 "$(cat "${STATE_DIR}/playback.pid" 2>/dev/null)" 2>/dev/null
            ;;
        spotify)
            # No local process to check (Raspotify is a permanent system
            # service, not something this plugin starts/stops) - ask the
            # Web API whether our device is still the one actively playing.
            local token device_name
            token="$(bash "${HERE}/spotify_token.sh" 2>/dev/null)"
            device_name="$(python3 -c "
import json
try:    print(json.load(open('$CFG_FILE')).get('spotify', {}).get('deviceName', ''))
except: print('')
" 2>/dev/null)"
            [[ -z "$token" || -z "$device_name" ]] && return 1
            curl -s -m 8 "https://api.spotify.com/v1/me/player" -H "Authorization: Bearer ${token}" 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    dev = (d.get('device') or {}).get('name', '')
    ok = (dev == '$device_name' and d.get('is_playing'))
except Exception:
    ok = False
print('alive' if ok else 'dead')
" 2>/dev/null | grep -q alive
            ;;
        *)
            return 1
            ;;
    esac
}
