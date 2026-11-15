#!/usr/bin/env bash
# Encore Radio - fetch the subscriber's SiriusXM channel lineup and cache it
# for the plugin page's channel picker.
#
# Runs as root (dispatched via the "Encore Radio - Load SiriusXM Channels"
# FPP Command) because it has to start the aiosxm proxy, which logs in with
# the subscriber's credentials and binds its loopback port - the same root
# context every other playback script assumes. The plugin page itself (PHP,
# unprivileged `fpp` user) can't do that directly, so it dispatches this and
# then reads the JSON we write here.
#
# Output: state/sxm_channels.json, one of:
#   {"status":"ok","fetchedAt":<epoch>,"count":N,"channels":[ {...}, ... ]}
#   {"status":"error","fetchedAt":<epoch>,"message":"..."}
# Each channel: {number,name,shortName,id,type,logo,unentitled,offAir}.
#
# If the proxy was NOT already running when we started, we stop it again when
# done - loading the lineup for the picker shouldn't leave an idle, logged-in
# SiriusXM session holding the port when nothing is playing.

set -uo pipefail

CFG_DIR="/home/fpp/media/plugindata/fpp-EncoreRadio"
STATE_DIR="/home/fpp/media/plugins/fpp-EncoreRadio/state"
LOG_FILE="${MEDIADIR:-/home/fpp/media}/logs/plugin-fpp-EncoreRadio.log"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_FILE="${STATE_DIR}/sxm_channels.json"
PROXY="${HERE}/er_sxm_proxy.sh"

mkdir -p "$STATE_DIR" 2>/dev/null || true

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [sxm-channels] $*" >> "$LOG_FILE"; }

# Write {"status":"error",...} and exit 0 - the dispatcher only cares that the
# file is fresh; the UI reads status/message from it.
write_error() {
    local msg="$1"
    MSG="$msg" python3 -c "
import json, os, time
json.dump({'status':'error','fetchedAt':int(time.time()),'message':os.environ['MSG']},
          open('${OUT_FILE}.tmp','w'))
" 2>/dev/null && mv -f "${OUT_FILE}.tmp" "$OUT_FILE" 2>/dev/null || true
    log "ERROR: $msg"
}

# Was the proxy already up before we touched it? (Decides whether we stop it
# again afterward.) "running pid=.. port=.." vs "stopped".
WAS_RUNNING=0
if bash "$PROXY" status 2>/dev/null | grep -q '^running'; then
    WAS_RUNNING=1
fi

cleanup() {
    if [[ "$WAS_RUNNING" -eq 0 ]]; then
        bash "$PROXY" stop >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

log "Loading SiriusXM channel lineup for the picker"
CHANNELS_JSON="$(bash "$PROXY" channels 2>/dev/null)"
if [[ -z "$CHANNELS_JSON" ]]; then
    # er_sxm_proxy.sh already logged the specific reason (no creds, bad login,
    # proxy didn't come up, etc). Give the UI a human message.
    write_error "Could not load channels. Check that your SiriusXM username/password are entered and saved, and see the Encore Radio log for details."
    exit 0
fi

# Slim the raw /channels array to just what the picker needs. JSON is piped
# via stdin (never interpolated into the -c string) so a channel title with
# quotes can't break the Python source.
if ! printf '%s' "$CHANNELS_JSON" | python3 -c "
import json, sys, time

try:
    chans = json.load(sys.stdin)
except Exception:
    sys.exit(2)
if not isinstance(chans, list):
    sys.exit(2)

def logo(c):
    imgs = c.get('images') or []
    # Prefer a roughly-square tile for a dropdown thumbnail; fall back to the
    # first image with a URL, else none.
    square = [i for i in imgs if (i.get('aspect_ratio') in ('1:1', '1x1')) and i.get('url')]
    if square:
        return square[0]['url']
    for i in imgs:
        if i.get('url'):
            return i['url']
    return ''

out = []
for c in chans:
    if not isinstance(c, dict):
        continue
    cid = c.get('id') or ''
    if not cid:
        continue
    out.append({
        'number': c.get('channel_number'),
        'name': c.get('title') or c.get('title_short') or '',
        'shortName': c.get('title_short') or '',
        'id': cid,
        'type': c.get('type') or 'channel-linear',
        'genre': c.get('genre') or '',
        'logo': logo(c),
        'unentitled': bool(c.get('unentitled')),
        'offAir': bool(c.get('off_air')),
    })

# Sort by numeric channel number when present (string/None sink to the end),
# then by name - so the picker reads like the SiriusXM guide.
def sortkey(e):
    n = e.get('number')
    try:
        return (0, int(n))
    except (TypeError, ValueError):
        return (1, (e.get('name') or '').lower())
out.sort(key=sortkey)

json.dump({'status':'ok','fetchedAt':int(time.time()),'count':len(out),'channels':out},
          open('${OUT_FILE}.tmp','w'))
" ; then
    write_error "Loaded the channel list but could not parse it. See the Encore Radio log."
    exit 0
fi

mv -f "${OUT_FILE}.tmp" "$OUT_FILE" 2>/dev/null || true
COUNT="$(python3 -c "import json;print(json.load(open('$OUT_FILE')).get('count',0))" 2>/dev/null || echo '?')"
log "Cached ${COUNT} SiriusXM channels for the picker"
exit 0
