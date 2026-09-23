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

# Direct fallback in case er_stop.sh above didn't run or didn't get this
# far (its own failure is swallowed by `|| true`) - a live CIFS mount left
# behind here points at a NAS the plugin directory (with the only tooling
# that knew how to unmount it) is about to be deleted out from under.
NETSHARE_MOUNT="/run/fpp-EncoreRadio-netshare"
if mountpoint -q "$NETSHARE_MOUNT" 2>/dev/null; then
  umount "$NETSHARE_MOUNT" 2>/dev/null || umount -l "$NETSHARE_MOUNT" 2>/dev/null || true
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

# The encoreradio-pulse.service unit file only ever exists when THIS
# plugin was the one that set up the shared PulseAudio socket
# (/run/pulse/native) - if Announcement Assistant (or a previous Encore
# Radio install) got there first, fpp_install.sh's
# setup_system_pulseaudio_if_needed() detects the existing socket and
# never creates this unit at all. So its presence/absence is a reliable
# signal for whether it's safe to revert: reverting unconditionally would
# risk breaking AA's audio if AA is relying on the same socket; skipping
# it unconditionally (the previous behavior) left every trace of Encore
# Radio's own PulseAudio changes in place even when nothing else was
# using them, which the Plugin Guidelines don't allow ("no carve-out for
# another plugin might be using it" - but that carve-out only applies
# when it's actually true, which this checks for rather than assumes).
PULSE_SVC="/etc/systemd/system/encoreradio-pulse.service"
if [[ -f "$PULSE_SVC" ]]; then
  log "Reverting Encore Radio's PulseAudio setup (nothing else appears to depend on it)"
  systemctl stop encoreradio-pulse.service 2>/dev/null || true
  systemctl disable encoreradio-pulse.service 2>/dev/null || true
  rm -f "$PULSE_SVC" || true
  systemctl daemon-reload 2>/dev/null || true

  # Every step below is `|| true`'d deliberately: the plugin directory
  # gets rm -rf'd right after this script exits regardless of its exit
  # code (scripts/uninstall_plugin), so there's no second chance to finish
  # teardown - one unguarded failure under `set -e` would abort the rest
  # of this block (including the restartFlag at the very end) rather than
  # just skip its own step.
  SYSTEM_PA="/etc/pulse/system.pa"
  SYSTEM_PA_BAK="${SYSTEM_PA}.er.bak"
  if [[ -f "$SYSTEM_PA_BAK" ]]; then
    mv -f "$SYSTEM_PA_BAK" "$SYSTEM_PA" || true
    log "Restored original /etc/pulse/system.pa from backup"
  elif [[ -f "$SYSTEM_PA" ]]; then
    rm -f "$SYSTEM_PA" || true
    log "Removed Encore Radio's system.pa (no pre-install backup existed)"
  fi

  CLIENT_CONF="/home/fpp/.config/pulse/client.conf"
  if [[ -f "$CLIENT_CONF" ]]; then
    rm -f "$CLIENT_CONF" || true
    log "Removed fpp user's Pulse client pin"
  fi
  pkill -u fpp pulseaudio 2>/dev/null || true
else
  log "encoreradio-pulse.service not present - Encore Radio never owned the shared PulseAudio setup (or another plugin does) - leaving PulseAudio untouched."
fi

# Config (encoreradio.json) is intentionally left in place so a reinstall
# doesn't lose the owner's source/announcement settings. State (PID files,
# trial-hour counters) is left too - trial tracking is meant to survive
# uninstall/reinstall by design (see license/trial-hours gating).
log "Stopped any running Encore Radio processes. Config and state left in place."

# fppd only reads commands/descriptions.json once, at its own startup - it
# never re-reads it in response to a plugin uninstall, so the "Encore
# Radio - Start"/"Stop" commands would otherwise silently linger as ghosts
# until fppd happens to restart for an unrelated reason. Same restartFlag
# mechanism fpp_install.sh already uses.
set +u
. "${FPPDIR:-/opt/fpp}/scripts/common" 2>/dev/null || true
set -u
setSetting restartFlag 1 2>/dev/null || true
