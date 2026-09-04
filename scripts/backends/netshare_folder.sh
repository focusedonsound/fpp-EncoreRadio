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
# `mount` needs root. An FPP Schedule entry firing this via fppd already
# runs as root, but the "Start Now" button on the plugin page goes through
# PHP-FPM instead, which runs as the unprivileged `fpp` user - confirmed on
# real hardware (mount.cifs failed with "permission denied" under that
# path). `fpp` already has passwordless sudo on every FPP image (standard,
# same as the Raspberry Pi OS default user), so `sudo mount`/`sudo umount`
# works identically from both invocation paths - a no-op elevation when
# already root, a real one otherwise.

set -euo pipefail

CFG_FILE="/home/fpp/media/config/encoreradio.json"
LOG_FILE="/home/fpp/media/logs/EncoreRadio.log"
STATE_DIR="/home/fpp/media/plugins/fpp-EncoreRadio/state"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOUNT_POINT="${STATE_DIR}/netshare_mount"
PLAYLIST_FILE="${STATE_DIR}/netshare_playlist.txt"

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

if [[ -z "$SHARE_PATH" ]]; then
    log "ERROR: no share path configured (netshare.sharePath is empty)"
    exit 1
fi

mkdir -p "$MOUNT_POINT" "$STATE_DIR" 2>/dev/null || true

# Clean remount every time rather than trusting a stale mount from a
# previous run - the share/folder/credentials may have changed since.
if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
    sudo umount "$MOUNT_POINT" 2>/dev/null || sudo umount -l "$MOUNT_POINT" 2>/dev/null || true
fi

# CIFS has no native POSIX permissions, so without uid/gid/file_mode/
# dir_mode the kernel driver defaults the mount to root-only-readable -
# confirmed on real hardware: the mount itself succeeds fine (that part
# runs elevated via sudo), but ffmpeg reading the files afterward (as the
# unprivileged `fpp` user, same as everything else this plugin runs as)
# then fails with "Operation not permitted". Map ownership to fpp instead.
FPP_UID="$(id -u fpp)"
FPP_GID="$(id -g fpp)"
if [[ -n "$USERNAME" ]]; then
    MOUNT_OPTS="username=${USERNAME},password=${PASSWORD},uid=${FPP_UID},gid=${FPP_GID},file_mode=0644,dir_mode=0755,ro"
else
    MOUNT_OPTS="guest,uid=${FPP_UID},gid=${FPP_GID},file_mode=0644,dir_mode=0755,ro"
fi

log "Mounting ${SHARE_PATH} (user=${USERNAME:-guest})"
if ! sudo mount -t cifs "$SHARE_PATH" "$MOUNT_POINT" -o "$MOUNT_OPTS" 2>>"$LOG_FILE"; then
    log "ERROR: failed to mount ${SHARE_PATH} - check share path/credentials, and that the share is reachable from this device"
    exit 1
fi

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
: > "$PLAYLIST_FILE"
for ((rep = 0; rep < REPEAT_COUNT; rep++)); do
    while IFS= read -r -d '' f; do
        escaped="${f//\'/\'\\\'\'}"
        echo "file '${escaped}'" >> "$PLAYLIST_FILE"
    done < <(printf '%s\0' "${FILES[@]}" | shuf -z)
done

log "Found ${FILE_COUNT} audio files - starting relay"
"${HERE}/er_relay.sh" start playlist "$PLAYLIST_FILE"
