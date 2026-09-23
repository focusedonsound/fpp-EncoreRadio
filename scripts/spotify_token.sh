#!/usr/bin/env bash
# Encore Radio - Spotify Web API access-token helper.
#
# Prints a valid access token to stdout, refreshing it first if expired.
# This is the user's OWN Developer App (client ID/secret they registered
# and authorized via www/spotify_auth.php + spotify_callback.php) - not
# related to librespot/Raspotify's own separate Zeroconf pairing, which
# authenticates the Connect device itself, not our Web API calls.
#
# Usage: TOKEN="$(bash spotify_token.sh)" || exit 1

set -uo pipefail

CFG_FILE="/home/fpp/media/plugindata/fpp-EncoreRadio/encoreradio.json"
LOG_FILE="${MEDIADIR:-/home/fpp/media}/logs/plugin-fpp-EncoreRadio.log"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [spotify-token] $*" >> "$LOG_FILE"; }

read -r CLIENT_ID CLIENT_SECRET REFRESH_TOKEN ACCESS_TOKEN EXPIRES_AT < <(python3 -c "
import json
try:
    s = json.load(open('$CFG_FILE')).get('spotify', {})
    print(s.get('clientId',''), s.get('clientSecret',''), s.get('refreshToken',''), s.get('accessToken',''), s.get('tokenExpiresAt', 0))
except Exception:
    print('', '', '', '', 0)
")

if [[ -z "$CLIENT_ID" || -z "$CLIENT_SECRET" || -z "$REFRESH_TOKEN" ]]; then
    log "ERROR: Spotify not connected (missing client id/secret/refresh token)"
    exit 1
fi

NOW="$(date +%s)"
# Refresh a bit early (60s margin) rather than racing an access token that
# expires mid-request.
if [[ -n "$ACCESS_TOKEN" && "$EXPIRES_AT" -gt $((NOW + 60)) ]]; then
    echo "$ACCESS_TOKEN"
    exit 0
fi

log "Access token missing/expired, refreshing"
RESP="$(curl -s -m 10 -X POST "https://accounts.spotify.com/api/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -u "${CLIENT_ID}:${CLIENT_SECRET}" \
    -d "grant_type=refresh_token" \
    -d "refresh_token=${REFRESH_TOKEN}")"

NEW_ACCESS="$(echo "$RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)"
EXPIRES_IN="$(echo "$RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('expires_in', 0))" 2>/dev/null || echo 0)"
# Spotify only returns a new refresh_token sometimes; keep the old one if absent.
NEW_REFRESH="$(echo "$RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('refresh_token',''))" 2>/dev/null)"

if [[ -z "$NEW_ACCESS" ]]; then
    log "ERROR: refresh failed: $RESP"
    exit 1
fi

# Passed via the environment, not spliced into the source string below -
# NEW_ACCESS/NEW_REFRESH come straight from Spotify's token-endpoint
# response body, so a stray quote in either would otherwise land as
# arbitrary Python source in a script that runs as root.
NEW_ACCESS="$NEW_ACCESS" NEW_REFRESH="$NEW_REFRESH" NEW_EXPIRES_AT="$((NOW + EXPIRES_IN))" python3 -c "
import json, os
cfg = json.load(open('$CFG_FILE'))
cfg.setdefault('spotify', {})
cfg['spotify']['accessToken'] = os.environ['NEW_ACCESS']
cfg['spotify']['tokenExpiresAt'] = int(os.environ['NEW_EXPIRES_AT'])
if os.environ.get('NEW_REFRESH'):
    cfg['spotify']['refreshToken'] = os.environ['NEW_REFRESH']
tmp = '$CFG_FILE.tmp'
json.dump(cfg, open(tmp, 'w'), indent=2)
os.replace(tmp, '$CFG_FILE')
os.chmod('$CFG_FILE', 0o600)
" 2>/dev/null || log "WARNING: failed to persist refreshed token"

echo "$NEW_ACCESS"
