#!/usr/bin/env bash
# Encore Radio - keep raspotify.service on only while Spotify is actually
# configured/used, rather than 24/7 from the moment the plugin is
# installed. Every free-tier install otherwise broadcasts a permanent
# Spotify Connect device on the LAN whether or not the operator ever
# touches the Spotify (premium) source - the Plugin Guidelines want a
# system service started only when the feature it belongs to is
# selected, not unconditionally at install.
#
# Called from fpp_install.sh (root already) and from the "Encore Radio -
# Sync Spotify Service" FPP Command that www/save.php dispatches after
# every config save (fppd runs Commands as root - see
# scripts/backends/netshare_folder.sh for why that's the only way this
# script can touch systemctl without sudo).

set -uo pipefail

CFG_FILE="/home/fpp/media/plugindata/fpp-EncoreRadio/encoreradio.json"
LOG_FILE="${MEDIADIR:-/home/fpp/media}/logs/plugin-fpp-EncoreRadio.log"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [spotify-sync] $*" >> "$LOG_FILE"; }

command -v systemctl >/dev/null 2>&1 || exit 0
systemctl list-unit-files raspotify.service >/dev/null 2>&1 || exit 0
[[ -f "$CFG_FILE" ]] || exit 0

# "Configured/used" = the operator has entered a Spotify Developer App
# client ID (the one-time setup step that has to happen before pairing
# can even be attempted), or Spotify is the active source, or it appears
# anywhere in a Rotation/Fallback chain.
SPOTIFY_IN_USE="$(python3 -c "
import json
try:
    cfg = json.load(open('$CFG_FILE'))
except Exception:
    print('False'); raise SystemExit

in_use = bool(cfg.get('spotify', {}).get('clientId', '').strip())
in_use = in_use or cfg.get('source') == 'spotify'
in_use = in_use or any(e.get('source') == 'spotify' for e in cfg.get('rotation', {}).get('entries', []))
in_use = in_use or 'spotify' in cfg.get('fallback', {}).get('chain', [])
print(in_use)
" 2>/dev/null)"

if [[ "$SPOTIFY_IN_USE" == "True" ]]; then
    if ! systemctl is-active --quiet raspotify.service 2>/dev/null; then
        systemctl enable --now raspotify.service 2>&1 | while IFS= read -r l; do log "$l"; done
        log "Spotify configured - enabled and started raspotify.service"
    fi
else
    if systemctl is-enabled --quiet raspotify.service 2>/dev/null || systemctl is-active --quiet raspotify.service 2>/dev/null; then
        systemctl disable --now raspotify.service 2>&1 | while IFS= read -r l; do log "$l"; done
        log "Spotify not configured/used - disabled raspotify.service"
    fi
fi
