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

# Config (encoreradio.json) is intentionally left in place so a reinstall
# doesn't lose the owner's source/announcement settings. State (PID files,
# trial-hour counters) is left too - trial tracking is meant to survive
# uninstall/reinstall by design (see license/trial-hours gating).
log "Stopped any running Encore Radio processes. Config and state left in place."
