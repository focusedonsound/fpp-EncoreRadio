#!/bin/bash
set -euo pipefail

PLUGIN_ID="EncoreRadio"
STATE_DIR="/home/fpp/media/plugins/fpp-EncoreRadio/state"

log() { echo "[$PLUGIN_ID] $*"; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Best-effort: stop anything the plugin left running (relay, pianobar, librespot).
if [[ -x "${here}/scripts/er_stop.sh" ]]; then
  "${here}/scripts/er_stop.sh" >/dev/null 2>&1 || true
fi

# Raspotify's systemd service is exclusively ours - nothing else in this
# ecosystem uses it - so it's safe to stop/disable on uninstall. The
# raspotify package itself is left installed (a `Reinstall All` or plugin
# reinstall shouldn't have to re-download a ~15MB .deb, and Spotify device
# pairing state lives in its cache dir, which disabling the service doesn't
# touch).
if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files raspotify.service >/dev/null 2>&1; then
  systemctl stop raspotify.service 2>/dev/null || true
  systemctl disable raspotify.service 2>/dev/null || true
  log "Stopped and disabled raspotify.service"
fi

# encoreradio-pulse.service is deliberately NOT touched here: it's a
# shared PulseAudio socket (/run/pulse/native) that Announcement Assistant
# (or a future install of it) may already be relying on if it deferred to
# "reuse the existing socket" during its own install - see
# docs/troubleshooting.md. Stopping it here could silently break another
# installed plugin's audio with no way for this script to know whether
# that's actually the case.

# Config (encoreradio.json) is intentionally left in place so a reinstall
# doesn't lose the owner's source/announcement settings. State (PID files,
# trial-hour counters) is left too - trial tracking is meant to survive
# uninstall/reinstall by design (see license/trial-hours gating).
log "Stopped any running Encore Radio processes. Config and state left in place."
