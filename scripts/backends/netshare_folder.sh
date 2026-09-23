#!/usr/bin/env bash
# Encore Radio - Network Share backend (free tier).
#
# Lets the owner point at a folder of music on an existing SMB/CIFS share
# (a NAS, a PC's shared folder, etc.) instead of having to copy files onto
# the Pi's own storage - the point being a much larger library than an SD
# card could hold. Mounts the share, shuffles the audio files found in the
# chosen folder into an ffmpeg concat playlist, and hands that to the same
# local relay every other source uses (er_relay.sh's "playlist" mode loops
# it forever, so it behaves like a continuous station).
#
# `mount` needs root. This script is only ever reached via an actual FPP
# Command (commands/er_cmd_start.sh, invoked by fppd - see www/start.php,
# which dispatches through FPP's own POST /api/command/{name} API rather
# than exec()'ing scripts directly), and fppd's own Command execution
# already runs as root - confirmed by reading FalconChristmas/fpp's
# ScriptCommand::run() (Plugins.cpp), which forks+execve()s the plugin
# script from fppd's own (root) process. No `sudo` needed, and none used -
# the FPP plugin guidelines explicitly disallow it ("install/hook scripts
# already run as root" - the same is true of Commands).

set -euo pipefail

CFG_FILE="/home/fpp/media/plugindata/fpp-EncoreRadio/encoreradio.json"
LOG_FILE="${MEDIADIR:-/home/fpp/media}/logs/plugin-fpp-EncoreRadio.log"
STATE_DIR="/home/fpp/media/plugins/fpp-EncoreRadio/state"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Deliberately NOT under media/ - FPP's own file manager, backup, and
# crash bundler walk media/ and would stat/open anything under it,
# including a mountpoint. If the NAS ever goes away, that would hang
# those (unrelated) processes in uninterruptible sleep waiting on the
# kernel CIFS client, not just this plugin's own requests. /run is
# tmpfs, always exists, and is never walked by anything else in FPP.
MOUNT_POINT="/run/fpp-EncoreRadio-netshare"
PLAYLIST_FILE="${STATE_DIR}/netshare_playlist.txt"
CREDS_FILE="/home/fpp/media/plugindata/fpp-EncoreRadio/netshare_creds"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [netshare] $*" >> "$LOG_FILE"; }

cfg() {
    python3 -c "
import json
try:    print(json.load(open('$CFG_FILE')).get('netshare', {}).get('$1', ''))
except: print('')
" 2>/dev/null || echo ""
}

SHARE_PATH="$(cfg sharePath)"
USERNAME="$(cfg username)"
PASSWORD="$(cfg password)"
FOLDER="$(cfg folder)"

# Strips CR/LF so username/password can never inject a second directive
# into the credentials file mount(8) parses below - same reasoning as
# pandora_pianobar.sh's strip_crlf for pianobar's config.
strip_crlf() { printf '%s' "${1//$'\r'/}" | tr -d '\n'; }
USERNAME="$(strip_crlf "$USERNAME")"
PASSWORD="$(strip_crlf "$PASSWORD")"

if [[ -z "$SHARE_PATH" ]]; then
    log "ERROR: no share path configured (netshare.sharePath is empty)"
    exit 1
fi

# A value starting with "-" would be parsed by mount(8) as an option, not
# a device, if it ever ended up first on the command line - www/save.php
# already rejects this at save time, but don't trust that alone.
if [[ "$SHARE_PATH" == -* ]]; then
    log "ERROR: invalid share path (starts with '-'): ${SHARE_PATH}"
    exit 1
fi

# Reject ".." so FOLDER can't escape the mountpoint once joined onto it
# below - same reasoning as the save-time check in www/save.php.
if [[ "$FOLDER" == *..* ]]; then
    log "ERROR: invalid folder (contains '..'): ${FOLDER}"
    exit 1
fi

mkdir -p "$MOUNT_POINT" "$STATE_DIR" 2>/dev/null || true

# Clean remount every time rather than trusting a stale mount from a
# previous run - the share/folder/credentials may have changed since.
if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
    umount "$MOUNT_POINT" 2>/dev/null || umount -l "$MOUNT_POINT" 2>/dev/null || true
fi

# Credentials file instead of username=/password= on the mount command
# line, where they'd be visible to anything that can read this process's
# argv (e.g. /proc/<pid>/cmdline, `ps auxww`) for as long as the mount
# command runs. 0600, written fresh each run, never left with a stale
# password from a previous config if the share is later set back to guest.
: > "$CREDS_FILE"
chmod 600 "$CREDS_FILE"
if [[ -n "$USERNAME" ]]; then
    printf 'username=%s\npassword=%s\n' "$USERNAME" "$PASSWORD" > "$CREDS_FILE"
fi

# CIFS has no native POSIX permissions, so without uid/gid/file_mode/
# dir_mode the kernel driver defaults the mount to root-only-readable.
# This script and everything it starts (the relay, ffplay) all run as
# root via fppd's own Command execution, so that alone wouldn't actually
# block anything here - mapped to fpp anyway so the mounted files are
# readable the same way regardless of which user ends up touching them.
FPP_UID="$(id -u fpp)"
FPP_GID="$(id -g fpp)"
# soft (not the kernel default of hard) + a bounded timeo/retrans: if the
# NAS drops off the network mid-session, in-flight I/O against this mount
# fails after a few seconds instead of retrying forever in uninterruptible
# sleep - the specific hang this mountpoint's own operations could
# otherwise cause (moving it out of media/ above keeps that hang from
# reaching FPP's *other* processes, but doesn't stop it from reaching
# this plugin's own relay/ffmpeg without `soft` too).
COMMON_OPTS="uid=${FPP_UID},gid=${FPP_GID},file_mode=0644,dir_mode=0755,ro,soft,timeo=30,retrans=2"
if [[ -n "$USERNAME" ]]; then
    MOUNT_OPTS="credentials=${CREDS_FILE},${COMMON_OPTS}"
else
    MOUNT_OPTS="guest,${COMMON_OPTS}"
fi

log "Mounting ${SHARE_PATH} (user=${USERNAME:-guest})"
if ! mount -t cifs "$SHARE_PATH" "$MOUNT_POINT" -o "$MOUNT_OPTS" 2>>"$LOG_FILE"; then
    rm -f "$CREDS_FILE"
    log "ERROR: failed to mount ${SHARE_PATH} - check share path/credentials, and that the share is reachable from this device"
    exit 1
fi

# The kernel already has the credentials it needs for this mount's
# lifetime; nothing else reads this file once mount(8) has returned, so
# don't leave it sitting on disk until the next mount attempt.
rm -f "$CREDS_FILE"

SEARCH_DIR="$MOUNT_POINT"
if [[ -n "$FOLDER" ]]; then
    # Trim any leading/trailing slashes the owner may have typed so it
    # joins cleanly onto MOUNT_POINT either way.
    CLEAN_FOLDER="${FOLDER#/}"
    CLEAN_FOLDER="${CLEAN_FOLDER%/}"
    SEARCH_DIR="${MOUNT_POINT}/${CLEAN_FOLDER}"
fi

if [[ ! -d "$SEARCH_DIR" ]]; then
    log "ERROR: folder not found on share: ${FOLDER:-<share root>}"
    exit 1
fi

# Scan once, then write the shuffled list into the concat playlist many
# times over (each repetition freshly reshuffled) rather than relying on
# ffmpeg's -stream_loop, which doesn't reliably loop the concat demuxer
# (see er_relay.sh) - this gives the same "never runs out during a single
# after-hours session, plays in a different order each pass" result
# without it. REPEAT_COUNT is a flat constant regardless of library size:
# for a small folder it guarantees hours of runtime; for a large one, one
# pass is already long enough that repeating it further costs nothing but
# a slightly bigger (still tiny, plain-text) playlist file.
mapfile -d '' -t FILES < <(find "$SEARCH_DIR" -type f \( \
        -iname '*.mp3' -o -iname '*.flac' -o -iname '*.m4a' \
        -o -iname '*.aac' -o -iname '*.ogg' -o -iname '*.wav' \
    \) -print0)
FILE_COUNT=${#FILES[@]}

if [[ "$FILE_COUNT" -eq 0 ]]; then
    log "ERROR: no audio files found in ${SEARCH_DIR}"
    exit 1
fi

# Concat-file syntax needs each path wrapped in single quotes with any
# embedded single quote escaped as '\'' (ffmpeg's own documented escaping
# for this format) - filenames from a real music library routinely contain
# apostrophes (e.g. "Ain't").
REPEAT_COUNT=200
# Single redirect around the whole loop, not `>>` on each line: reopening
# the file per line, times FILE_COUNT * REPEAT_COUNT, turns a large
# library (thousands of tracks) into hundreds of thousands of individual
# append-opens - this runs inside a blocking FPP Command (er_cmd_start.sh),
# so that cost lands on fppd's command thread and whoever's waiting on
# Start/Stop, not just this script.
{
    for ((rep = 0; rep < REPEAT_COUNT; rep++)); do
        while IFS= read -r -d '' f; do
            escaped="${f//\'/\'\\\'\'}"
            echo "file '${escaped}'"
        done < <(printf '%s\0' "${FILES[@]}" | shuf -z)
    done
} > "$PLAYLIST_FILE"

log "Found ${FILE_COUNT} audio files - starting relay"
"${HERE}/er_relay.sh" start playlist "$PLAYLIST_FILE"
