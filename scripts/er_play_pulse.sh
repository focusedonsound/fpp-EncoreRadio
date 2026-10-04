#!/usr/bin/env bash
# Encore Radio - FPP 9.x playback path.
#
# Plays the local relay URL into the PulseAudio sink via ffplay - the same
# audio path Announcement Assistant expects to duck (it fades whatever's
# an active PulseAudio sink-input, not just FPP's own show audio).

set -euo pipefail

CFG_FILE="/home/fpp/media/plugindata/fpp-EncoreRadio/encoreradio.json"
STATE_DIR="/home/fpp/media/plugins/fpp-EncoreRadio/state"
LOG_FILE="${MEDIADIR:-/home/fpp/media}/logs/plugin-fpp-EncoreRadio.log"
PID_FILE="${STATE_DIR}/playback.pid"
SETTINGS_FILE="/home/fpp/media/settings"

mkdir -p "$STATE_DIR" 2>/dev/null || true

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [pulse-play] $*" >> "$LOG_FILE"; }

# Explicit PULSE_SERVER, matching er_apply_volume.sh's own established
# convention here (see its comment) rather than relying on discovery.
PACTL=(env PULSE_SERVER=unix:/run/pulse/native pactl)

# Resolves the PipeWire sink name for FPP's currently-selected AudioOutput
# device, mirroring FPP core's own NormalizeAudioOutputToCardId() (www/
# common.php): an empty stored value means "whatever enumerates first" (we
# don't chase that - no target beats a wrong guess), a purely numeric value
# is a raw ALSA card INDEX resolved via /proc/asound/card<N>/id, anything
# else is already a stable ALSA card ID string. FPP's own PipeWire session
# names each hardware sink "fpp_alsa_<cardId>", lowercased - confirmed on
# real hardware: AudioOutput="S3" -> sink "fpp_alsa_s3".
#
# Real-hardware finding this exists to work around: ffplay has no way to
# target a PipeWire node directly (unlike FPP's own player, which always
# names fpp_alsa_<cardId> explicitly) - SDL's pulseaudio driver only
# understands PulseAudio's "default sink", which can independently drift to
# a different card than AudioOutput after a reboot. Confirmed live:
# AudioOutput="S3" while ffplay's sink-input was still landing on the Pi's
# own onboard fpp_alsa_headphones (RUNNING) with fpp_alsa_s3 sitting
# SUSPENDED, untouched - audio was playing the whole time, just out of the
# wrong physical jack. FPP's native After Hours feature has the identical
# symptom for the identical reason (also relies on the OS default sink);
# FPP's own show/sequence playback is immune because it never relies on a
# default - it always names its target explicitly, same as this now does.
#
# Prints the sink name and returns 0 only when that sink actually exists
# right now - a guessed name that doesn't exist would leave ffplay with
# nowhere to play at all, which is strictly worse than today's "wrong but
# audible" default-sink behavior, so an unresolvable/unverifiable target
# falls back to doing nothing rather than forcing a guess.
resolve_target_sink() {
    local raw
    raw="$(python3 -c "
import re
try:
    for line in open('$SETTINGS_FILE'):
        m = re.match(r'^\s*AudioOutput\s*=\s*\"(.*)\"\s*\$', line)
        if m:
            print(m.group(1))
            break
except Exception:
    pass
" 2>/dev/null)"
    [[ -z "$raw" ]] && return 1

    local card_id="$raw"
    if [[ "$raw" =~ ^[0-9]+$ ]]; then
        local id_file="/proc/asound/card${raw}/id"
        [[ -f "$id_file" ]] || return 1
        card_id="$(cat "$id_file" 2>/dev/null)"
    fi
    # ALSA card IDs are restricted to this character set by the kernel
    # itself - matched defensively before this ever reaches a sink name.
    [[ "$card_id" =~ ^[A-Za-z0-9_]+$ ]] || return 1

    local sink_name="fpp_alsa_${card_id,,}"
    if "${PACTL[@]}" list sinks short 2>/dev/null | awk '{print $2}' | grep -qx "$sink_name"; then
        printf '%s' "$sink_name"
        return 0
    fi
    return 1
}

relay_port() {
    python3 -c "
import json
try:    print(int(json.load(open('$CFG_FILE')).get('relay', {}).get('port', 8123)))
except: print(8123)
" 2>/dev/null || echo 8123
}

# Detects whether this box's own FPP core build already contains the
# fpp#3021/#3030 fix, via FPP's own git checkout at /opt/fpp (present on
# any git-branch-based install/update - see changebranch.php - which is
# every supported FPP 10 install/update path). Returns failure (meaning
# "run the workaround") whenever this can't be determined one way or the
# other - a shallow clone with truncated history, or no /opt/fpp/.git at
# all (an image type this hasn't been seen on, but not one to guess
# "must be fixed" about) - rather than silently going quiet on a box this
# can't actually verify.
fpp_core_has_pipewire_link_fix() {
    [[ -d /opt/fpp/.git ]] || return 1
    local is_shallow
    is_shallow="$(git -C /opt/fpp rev-parse --is-shallow-repository 2>/dev/null)" || return 1
    [[ "$is_shallow" == "false" ]] || return 1
    git -C /opt/fpp merge-base --is-ancestor c1bb01ad3 HEAD 2>/dev/null || return 1
    git -C /opt/fpp merge-base --is-ancestor 3ac940c4a HEAD 2>/dev/null || return 1
    return 0
}

URL="http://127.0.0.1:$(relay_port)/stream"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
    kill "$(cat "$PID_FILE")" 2>/dev/null || true
    sleep 0.5
fi

# Works around a real FPP core PipeWire routing bug (fppd's own graph
# could leave the hardware sink permanently unlinked, especially after a
# reboot - see er_repair_pipewire_sink_link.sh) - not anything in this
# plugin, and the real fix (fpp#3021/#3030) has since landed in FPP core
# itself (commits c1bb01ad3 + 3ac940c4a). Reaching into FPP's own
# PipeWire graph at all is something a plugin shouldn't do routinely
# (PLUGIN_GUIDELINES.md §4.3) even when it's a harmless no-op on a
# healthy box, so only call this on a build that doesn't already contain
# the fix - once a box's FPP build has it, this step is skipped entirely
# rather than just quietly doing nothing.
if ! fpp_core_has_pipewire_link_fix; then
    bash "${HERE}/er_repair_pipewire_sink_link.sh" || true
fi

log "Playing via ffplay into PulseAudio: $URL"
# ffplay has no -ao flag (that's mpv/mplayer) - it outputs through SDL,
# so PulseAudio is selected via SDL_AUDIODRIVER, not a command-line arg.
ENV_ARGS=(SDL_AUDIODRIVER=pulseaudio)
TARGET_SINK="$(resolve_target_sink || true)"
if [[ -n "$TARGET_SINK" ]]; then
    log "Targeting PipeWire sink explicitly: $TARGET_SINK (resolved from AudioOutput setting)"
    # PULSE_SINK is libpulse's own standard env var for "default sink to
    # connect to" - honored by any PulseAudio-protocol client, ffplay/SDL
    # included, with no code change on their side needed.
    ENV_ARGS+=("PULSE_SINK=$TARGET_SINK")
else
    log "Could not resolve a specific target sink - falling back to the PulseAudio default sink"
fi
nohup env "${ENV_ARGS[@]}" ffplay -nodisp -autoexit -loglevel warning "$URL" \
    >> "$LOG_FILE" 2>&1 &
FFPLAY_PID=$!
echo "$FFPLAY_PID" > "$PID_FILE"
log "ffplay started pid=$FFPLAY_PID"

# Backgrounded: er_apply_volume.sh polls for up to 15s for the sink-input
# to actually register, which used to be an inline wait right here (issue
# #4 - a slow-to-connect stream could outlast the old 5s inline poll and
# silently leave volume unset). Backgrounding it means that longer poll
# costs nothing on Start's own response time.
nohup bash "${HERE}/er_apply_volume.sh" >> "$LOG_FILE" 2>&1 &
disown 2>/dev/null || true
