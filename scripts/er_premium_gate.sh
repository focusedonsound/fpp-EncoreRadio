#!/usr/bin/env bash
# Encore Radio - premium feature gate (Spotify, multi-source rotation).
#
# M5's license server (see fpp-EncoreRadio-license-server repo). Every
# call to it is still wrapped to fail soft (log + continue) rather than
# hard-block premium features on a network hiccup or the server being
# briefly down - that's intentional, not a leftover from when this was a
# placeholder.
#
# Trial: 10 cumulative hours of PREMIUM playback (not calendar time - see
# build plan for why usage-based beats calendar-based). No license key ->
# gate on trialSecondsUsed. License key present -> best-effort online
# validation with a grace period if the server can't be reached (common
# practice - a network hiccup or the server being down shouldn't brick a
# paying user's show).
#
# Usage:
#   bash er_premium_gate.sh check   -> exit 0 if allowed, 1 if blocked (prints reason to stdout)
#   bash er_premium_gate.sh remaining-seconds -> prints trial seconds remaining (0 if licensed or exhausted)

set -uo pipefail

LICENSE_SERVER_BASE="https://encoreradio-license.nscilingo.workers.dev/api"
CFG_FILE="/home/fpp/media/config/encoreradio.json"
LOG_FILE="/home/fpp/media/logs/EncoreRadio.log"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRIAL_LIMIT_SECONDS=$((10 * 3600))

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [premium-gate] $*" >> "$LOG_FILE"; }

license_cfg() {
    python3 -c "
import json
try:    print(json.load(open('$CFG_FILE')).get('license', {}).get('$1', $2))
except: print($2)
" 2>/dev/null
}

LICENSE_KEY="$(python3 -c "
import json
try:    print(json.load(open('$CFG_FILE')).get('license', {}).get('key', ''))
except: print('')
" 2>/dev/null)"
TRIAL_USED="$(license_cfg trialSecondsUsed 0)"
[[ -z "$TRIAL_USED" ]] && TRIAL_USED=0

validate_license_key() {
    local hwid
    hwid="$(bash "${HERE}/er_hwid.sh" 2>/dev/null)"
    # No "|| echo 000" fallback: curl's -w already prints "000" on its own
    # for a connection failure - the fallback double-fired on top of it,
    # confirmed on real hardware (see er_announce_scheduler.sh for the
    # same fix and fuller explanation).
    local http_code
    http_code="$(curl -s -m 8 -o /tmp/encoreradio_license_validate.json -w '%{http_code}' \
        -X POST "${LICENSE_SERVER_BASE}/validate" \
        -H "Content-Type: application/json" \
        -d "{\"key\":\"${LICENSE_KEY}\",\"hwid\":\"${hwid}\"}" 2>/dev/null)"

    if [[ "$http_code" == "200" ]]; then
        local valid
        valid="$(python3 -c "import json; print(json.load(open('/tmp/encoreradio_license_validate.json')).get('valid', False))" 2>/dev/null)"
        if [[ "$valid" == "True" ]]; then
            log "License validated OK"
            return 0
        else
            log "License server rejected key (not valid)"
            return 2
        fi
    elif [[ "$http_code" == "000" ]]; then
        log "WARNING: license server unreachable (placeholder endpoint, or network issue) - grace-period allow"
        return 0
    else
        log "License server returned HTTP $http_code - grace-period allow"
        return 0
    fi
}

cmd_check() {
    if [[ -n "$LICENSE_KEY" ]]; then
        if validate_license_key; then
            echo "licensed"
            exit 0
        else
            echo "License key present but rejected by the license server - check your key on the Encore Radio page."
            exit 1
        fi
    fi

    if [[ "$TRIAL_USED" -lt "$TRIAL_LIMIT_SECONDS" ]]; then
        echo "trial"
        exit 0
    fi

    echo "Trial hours used up. Register and enter a license key on the Encore Radio page to keep using Spotify."
    exit 1
}

cmd_remaining_seconds() {
    if [[ -n "$LICENSE_KEY" ]]; then
        echo 0
        return
    fi
    local remaining=$((TRIAL_LIMIT_SECONDS - TRIAL_USED))
    [[ "$remaining" -lt 0 ]] && remaining=0
    echo "$remaining"
}

case "${1:-}" in
    check) cmd_check ;;
    remaining-seconds) cmd_remaining_seconds ;;
    *)
        echo "Usage: $0 {check|remaining-seconds}" >&2
        exit 2
        ;;
esac
