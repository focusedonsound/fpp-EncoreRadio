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
# far (its own failure is swallowed by `|| true`) - a live Network Share
# batch scheduler left running here would otherwise keep fetching from the
# NAS after the plugin directory (the only thing that knows how to stop
# it) is deleted out from under it.
SCHED_PID_FILE="${STATE_DIR}/netshare_scheduler.pid"
if [[ -f "$SCHED_PID_FILE" ]]; then
  SCHED_PID="$(cat "$SCHED_PID_FILE" 2>/dev/null || echo "")"
  rm -f "$SCHED_PID_FILE"
  [[ -n "$SCHED_PID" ]] && kill "$SCHED_PID" 2>/dev/null || true
fi
rm -rf "${STATE_DIR}/netshare_stage" "${STATE_DIR}/netshare_remote_list.txt" 2>/dev/null || true
rm -f "/home/fpp/media/plugindata/fpp-EncoreRadio/netshare_authfile" 2>/dev/null || true

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
# Remove our own dependency marker first, then check whether anyone else's
# is still there - this is the actual reference count, not just "does my
# own unit file exist" (see fpp_install.sh's register_pulse_bridge_dependency
# for the other half). A marker from a plugin installed before this one
# shipped this mechanism won't exist yet, so this can under-count on an
# upgrade path crossing that boundary - acceptable: it only means one
# extra uninstall cycle before the count is trustworthy again, never a
# false "nobody needs this" teardown.
BRIDGE_OWNERS_DIR="/etc/fpp-plugins/pulse-bridge-owners"
rm -f "${BRIDGE_OWNERS_DIR}/fpp-EncoreRadio" 2>/dev/null || true
OTHER_BRIDGE_OWNERS=0
if [[ -d "$BRIDGE_OWNERS_DIR" ]] && [[ -n "$(ls -A "$BRIDGE_OWNERS_DIR" 2>/dev/null)" ]]; then
  OTHER_BRIDGE_OWNERS=1
fi

PULSE_SVC="/etc/systemd/system/encoreradio-pulse.service"
# The other plugin's own unit name - only relevant in the "we're the last
# one standing" branch below, where IT already uninstalled first and left
# its own unit running for us, so nothing else will ever clean it up if
# we don't.
OTHER_PULSE_SVC="/etc/systemd/system/announcementassistant-pulse.service"

if [[ "$OTHER_BRIDGE_OWNERS" -eq 1 ]]; then
  log "Another plugin still depends on the shared PulseAudio/PipeWire-pulse bridge - leaving it running."
elif [[ -f "$PULSE_SVC" ]]; then
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
  #
  # /etc/pulse/system.pa is only ever OURS to touch on the legacy (FPP
  # 9.x/no PipeWire) path - the PipeWire path never writes it at all (see
  # setup_system_pipewire_pulse() in fpp_install.sh), so its presence here
  # is only reverted alongside the .er.bak marker THIS plugin itself
  # creates before ever overwriting it - never an unconditional rm, which
  # would risk deleting a system.pa this plugin never touched (e.g. one
  # belonging to a real system pulseaudio install unrelated to us) on a
  # PipeWire box where encoreradio-pulse.service exists for a completely
  # different reason.
  SYSTEM_PA="/etc/pulse/system.pa"
  SYSTEM_PA_BAK="${SYSTEM_PA}.er.bak"
  if [[ -f "$SYSTEM_PA_BAK" ]]; then
    mv -f "$SYSTEM_PA_BAK" "$SYSTEM_PA" || true
    log "Restored original /etc/pulse/system.pa from backup"
  elif [[ -f "$SYSTEM_PA" ]] && grep -q "Encore Radio system PulseAudio config" "$SYSTEM_PA" 2>/dev/null; then
    rm -f "$SYSTEM_PA" || true
    log "Removed Encore Radio's system.pa (no pre-install backup existed)"
  fi

  CLIENT_CONF="/home/fpp/.config/pulse/client.conf"
  if [[ -f "$CLIENT_CONF" ]]; then
    rm -f "$CLIENT_CONF" || true
    log "Removed fpp user's Pulse client pin"
  fi
  pkill -u fpp pulseaudio 2>/dev/null || true
  pkill -u fpp pipewire-pulse 2>/dev/null || true
elif [[ -f "$OTHER_PULSE_SVC" ]]; then
  # We're the last plugin depending on the bridge (OTHER_BRIDGE_OWNERS was
  # 0), but AA's unit - not ours - is the one actually serving it, because
  # AA installed first. AA already uninstalled without tearing it down
  # (correctly, at the time - this plugin's marker was still present) and
  # nothing else is left to clean it up but us.
  log "Reverting Announcement Assistant's PulseAudio/PipeWire-pulse bridge (nothing else depends on it, and AA is no longer installed to do this itself)"
  systemctl stop announcementassistant-pulse.service 2>/dev/null || true
  systemctl disable announcementassistant-pulse.service 2>/dev/null || true
  rm -f "$OTHER_PULSE_SVC" || true
  systemctl daemon-reload 2>/dev/null || true
  pkill -u fpp pulseaudio 2>/dev/null || true
  pkill -u fpp pipewire-pulse 2>/dev/null || true
else
  log "No PulseAudio/PipeWire-pulse bridge unit present - Encore Radio never owned the shared setup (or another plugin does) - leaving PulseAudio untouched."
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
