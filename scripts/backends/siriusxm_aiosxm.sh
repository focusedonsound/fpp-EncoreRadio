#!/usr/bin/env bash
# Encore Radio - SiriusXM backend (premium tier), via the aiosxm proxy.
#
# Shape: this is the TuneIn "hand the relay a URL" path wrapped in the same
# premium gate Pandora/Spotify use. The aiosxm proxy (er_sxm_proxy.sh) logs
# in with the subscriber's credentials and re-serves the chosen channel as a
# loopback AES-128 HLS playlist; ffmpeg in er_relay.sh reads and decrypts that
# playlist exactly like any other stream URL. No PulseAudio null-sink capture
# (unlike Pandora) - the audio never leaves the HLS/ffmpeg path.
#
# Requires a SiriusXM subscription. Uses an unofficial, reverse-engineered
# SiriusXM API (via aiosxm) - personal use, at your own risk; SiriusXM can
# change their API and break this at any time (see docs/).

set -euo pipefail

CFG_FILE="/home/fpp/media/plugindata/fpp-EncoreRadio/encoreradio.json"
LOG_FILE="${MEDIADIR:-/home/fpp/media}/logs/plugin-fpp-EncoreRadio.log"
# ../ from scripts/backends/ resolves to the scripts/ dir (same as the other
# backends) - NOT the plugin root. er_relay.sh, er_premium_gate.sh,
# er_track_usage.sh and er_sxm_proxy.sh all live directly in scripts/.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [siriusxm] $*" >> "$LOG_FILE"; }

cfg() {
    python3 -c "
import json
try:    print(json.load(open('$CFG_FILE')).get('siriusxm', {}).get('$1', ''))
except: print('')
" 2>/dev/null || echo ""
}

# Premium gate - same "&& GATE_RC=0 || GATE_RC=$?" form as pandora_pianobar.sh:
# under `set -e` a plain `VAR="$(cmd)"` assignment aborts the script on cmd's
# nonzero exit before GATE_RC is ever captured or the error logged.
GATE_MSG="$(bash "${HERE}/er_premium_gate.sh" check)" && GATE_RC=0 || GATE_RC=$?
if [[ "$GATE_RC" -ne 0 ]]; then
    log "ERROR: $GATE_MSG"
    exit 1
fi
log "Premium gate: $GATE_MSG"

CHANNEL="$(cfg channel)"
if [[ -z "$CHANNEL" ]]; then
    log "ERROR: no SiriusXM channel configured (siriusxm.channel is empty)"
    exit 1
fi

# Start (or reuse) the aiosxm proxy. This also fails fast on a bad login
# (er_sxm_proxy.sh logs the specific reason).
if ! bash "${HERE}/er_sxm_proxy.sh" ensure >> "$LOG_FILE" 2>&1; then
    log "ERROR: SiriusXM proxy failed to start - see earlier log lines"
    exit 1
fi

# Entitlement check - a lapsed subscription still *authenticates* but every
# channel returns 403/NotEntitledError, so surface that as a clear reason
# instead of a silent failure mid-pipeline.
ENTITLED="$(bash "${HERE}/er_sxm_proxy.sh" entitlements 2>/dev/null | python3 -c "
import json, sys
try:    print('yes' if json.load(sys.stdin).get('entitled') else 'no')
except: print('unknown')
" 2>/dev/null || echo "unknown")"
if [[ "$ENTITLED" == "no" ]]; then
    log "ERROR: this SiriusXM account has no active entitlements - playback would fail. Check that the subscription is active and includes streaming."
    bash "${HERE}/er_sxm_proxy.sh" stop >/dev/null 2>&1 || true
    exit 1
fi

# Resolve the operator's channel (number or name) to a playlist URL.
STREAM_URL="$(bash "${HERE}/er_sxm_proxy.sh" url "$CHANNEL" 2>/dev/null || echo "")"
if [[ -z "$STREAM_URL" ]]; then
    log "ERROR: could not find a SiriusXM channel matching '${CHANNEL}' - check the channel number or name."
    bash "${HERE}/er_sxm_proxy.sh" stop >/dev/null 2>&1 || true
    exit 1
fi

log "Starting relay for SiriusXM channel '${CHANNEL}': ${STREAM_URL}"
"${HERE}/er_relay.sh" start url "$STREAM_URL"

# Count SiriusXM time against the premium trial, same as Pandora/Spotify.
bash "${HERE}/er_track_usage.sh" start
