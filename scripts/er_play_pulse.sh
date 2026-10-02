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

mkdir -p "$STATE_DIR" 2>/dev/null || true

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [pulse-play] $*" >> "$LOG_FILE"; }

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
nohup env SDL_AUDIODRIVER=pulseaudio ffplay -nodisp -autoexit -loglevel warning "$URL" \
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
