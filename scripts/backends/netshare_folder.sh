#!/usr/bin/env bash
# Encore Radio - Network Share backend (free tier).
#
# Lets the owner point at a folder of music on an existing SMB/CIFS share
# (a NAS, a PC's shared folder, etc.) instead of having to copy files onto
# the Pi's own storage. Reads the share entirely through smbclient (a
# user-space SMB client) rather than a kernel `mount -t cifs`: the FPP
# Plugin Guidelines don't accept filesystem mounts from plugins, because a
# dead/unreachable NAS behind a hard kernel mount can hang every unrelated
# process that ever stats a path under it (FPP's own file manager, backup,
# crash bundler) in uninterruptible sleep - not just this plugin's own
# requests. Reading through smbclient means a dead server only ever fails
# this plugin's own next fetch.
#
# The library can be far larger than local storage holds, so this never
# downloads the whole thing: it enumerates the folder once, then streams
# through it in small batches (netshare_batch_scheduler.sh), staging only
# a few tracks locally at a time and deleting each as it's played. See
# that script for the batch/prefetch design.
#
# This script's own job is just the one-time setup: enumerate the share,
# shuffle the file list, and hand off to the batch scheduler as a
# background daemon - same "start the pipeline and return quickly" shape
# as every other backend, since er_start_source.sh waits on this script
# returning before it starts polling the relay port.
#
# `smbclient` needs no special privilege beyond what this script already
# runs with. This script is only ever reached via an actual FPP Command
# (commands/er_cmd_start.sh, invoked by fppd - see www/start.php, which
# dispatches through FPP's own POST /api/command/{name} API rather than
# exec()'ing scripts directly), and fppd's own Command execution already
# runs as root - confirmed by reading FalconChristmas/fpp's
# ScriptCommand::run() (Plugins.cpp), which forks+execve()s the plugin
# script from fppd's own (root) process. No `sudo` needed, and none used -
# the FPP plugin guidelines explicitly disallow it ("install/hook scripts
# already run as root" - the same is true of Commands).

set -uo pipefail

CFG_FILE="/home/fpp/media/plugindata/fpp-EncoreRadio/encoreradio.json"
CFG_DIR="$(dirname "$CFG_FILE")"
LOG_FILE="${MEDIADIR:-/home/fpp/media}/logs/plugin-fpp-EncoreRadio.log"
STATE_DIR="/home/fpp/media/plugins/fpp-EncoreRadio/state"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

AUTH_FILE="${CFG_DIR}/netshare_authfile"
REMOTE_LIST_FILE="${STATE_DIR}/netshare_remote_list.txt"
SCHEDULER_PID_FILE="${STATE_DIR}/netshare_scheduler.pid"

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
# into the credentials file smbclient(1) parses below (its -A file uses
# the same "key = value" line format as pianobar's config, and is exposed
# to the same injection risk) - same reasoning as pandora_pianobar.sh's
# strip_crlf.
strip_crlf() { printf '%s' "${1//$'\r'/}" | tr -d '\n'; }
USERNAME="$(strip_crlf "$USERNAME")"
PASSWORD="$(strip_crlf "$PASSWORD")"

if [[ -z "$SHARE_PATH" ]]; then
    log "ERROR: no share path configured (netshare.sharePath is empty)"
    exit 1
fi

# SHARE_PATH is stored as "//host/share" (www/save.php's own format) -
# smbclient wants that as its first positional argument as-is. Reject a
# value starting with "-" so it can never be parsed as an smbclient option
# instead of a share - save.php already rejects this at save time, but
# don't trust that alone.
if [[ "$SHARE_PATH" == -* ]]; then
    log "ERROR: invalid share path (starts with '-'): ${SHARE_PATH}"
    exit 1
fi

# Reject ".." so FOLDER can't escape the share root once passed as
# smbclient's initial directory (-D) below - same reasoning as the
# save-time check in www/save.php.
if [[ "$FOLDER" == *..* ]]; then
    log "ERROR: invalid folder (contains '..'): ${FOLDER}"
    exit 1
fi

mkdir -p "$STATE_DIR" 2>/dev/null || true

# Credentials file instead of username=/password= on the smbclient command
# line, where they'd be visible to anything that can read this process's
# argv (e.g. /proc/<pid>/cmdline, `ps auxww`) for as long as it runs. This
# persists for the life of this playback session (the batch scheduler
# below needs it for every fetch, not just one) rather than being written
# fresh per-call - still 0600, still removed on Stop
# (er_stop_playback.sh), never left holding a stale password once the
# share config changes and this source is restarted.
: > "$AUTH_FILE"
chmod 600 "$AUTH_FILE"
if [[ -n "$USERNAME" ]]; then
    printf 'username = %s\npassword = %s\n' "$USERNAME" "$PASSWORD" > "$AUTH_FILE"
else
    printf 'username = guest\npassword = \n' > "$AUTH_FILE"
fi

# smbclient's -c command batch takes one string; "cd" understands quoted
# paths with spaces (the standard iTunes-style "Artist Name" folder), but
# not a literal double-quote inside the path itself - www/save.php already
# rejects that at save time, so this is defense in depth, not the only
# guard.
if [[ "$FOLDER" == *'"'* ]]; then
    log "ERROR: invalid folder (contains a double quote): ${FOLDER}"
    exit 1
fi

# One-time enumeration of the folder, recursively, filtered to audio
# extensions. Cost is bounded by whatever folder the owner points this
# at (same as the old mount-based version's `find` scan over it) - a
# folder scoped to one artist/album is fast; the whole library root on a
# large collection can take a while, same as it always could.
log "Enumerating ${SHARE_PATH}${FOLDER:+/$FOLDER} via smbclient…"
RAW_LISTING="$(smbclient "$SHARE_PATH" -A "$AUTH_FILE" \
    ${FOLDER:+-D "$FOLDER"} \
    -c 'recurse ON; ls' 2>>"$LOG_FILE")"
SMB_RC=$?
if [[ "$SMB_RC" -ne 0 ]]; then
    log "ERROR: smbclient could not reach/enumerate ${SHARE_PATH} (exit ${SMB_RC}) - check share path/credentials, and that the share is reachable from this device"
    rm -f "$AUTH_FILE"
    exit 1
fi

# smbclient's recursive `ls` prints a "\<subdir>" header line before each
# directory's contents, then "  <filename>  A  <size>  <date>" per file.
# Reconstruct each file's path relative to the scanned root by tracking
# the last-seen header line, and keep only files (flag column "A", not
# "D" for a directory) with an audio extension.
: > "$REMOTE_LIST_FILE"
CURRENT_DIR=""
while IFS= read -r line; do
    if [[ "$line" == \\* ]]; then
        CURRENT_DIR="${line#\\}"
        continue
    fi
    # Filename column is fixed-width-padded then attribute flags (a
    # contiguous run of letters like "A", "D", "AH", "AR") then a size
    # column - match on that rather than whitespace-splitting, since
    # filenames themselves routinely contain multiple spaces.
    if [[ "$line" =~ ^\ \ (.+[^\ ])\ +[ADHRSN]+\ +[0-9]+\ +[A-Za-z]{3}\  ]]; then
        fname="${BASH_REMATCH[1]}"
        [[ "$fname" == "." || "$fname" == ".." ]] && continue
        case "$fname" in
            *.[Mm][Pp]3|*.[Ff][Ll][Aa][Cc]|*.[Mm]4[Aa]|*.[Aa][Aa][Cc]|*.[Oo][Gg][Gg]|*.[Ww][Aa][Vv])
                # This path gets spliced into smbclient's own -c command
                # string later (netshare_batch_scheduler.sh's `get`) rather
                # than passed as a separate argv element - a literal `"`
                # breaks out of that quoting and a literal `\` collides
                # with both smbclient's own escape character AND the `\`
                # this script uses to join CURRENT_DIR/fname below. Skip
                # rather than try to perfectly round-trip either one: a
                # NAS owner can rename the one oddly-named file far more
                # easily than this script can safely re-derive smbclient's
                # exact quoting grammar for it.
                # fname is always a single atomic name component (never
                # path-joined), so either character appearing in it is
                # genuinely foreign - keep rejecting both.
                case "$fname" in
                    *'"'*|*'\'*)
                        log "WARNING: skipping '${CURRENT_DIR:+$CURRENT_DIR\\}${fname}' - filename contains a quote or backslash, unsafe to pass to smbclient"
                        continue
                        ;;
                esac
                # CURRENT_DIR is different: it's smbclient's own recursive
                # `ls` header line, which ALWAYS uses \ as the path
                # separator between folder levels - rejecting on backslash
                # here doesn't catch anything unsafe, it just rejects every
                # folder nested two or more levels deep (confirmed: a real
                # library's Christmas\Bing Crosby\*.mp3 was silently staging
                # nothing). Only the quote character is actually foreign in
                # a directory header.
                case "$CURRENT_DIR" in
                    *'"'*)
                        log "WARNING: skipping everything under '${CURRENT_DIR}' - folder name contains a quote, unsafe to pass to smbclient"
                        continue
                        ;;
                esac
                if [[ -n "$CURRENT_DIR" ]]; then
                    printf '%s\\%s\0' "$CURRENT_DIR" "$fname" >> "$REMOTE_LIST_FILE"
                else
                    printf '%s\0' "$fname" >> "$REMOTE_LIST_FILE"
                fi
                ;;
        esac
    fi
done <<< "$RAW_LISTING"

FILE_COUNT="$(tr -cd '\0' < "$REMOTE_LIST_FILE" | wc -c)"
if [[ "$FILE_COUNT" -eq 0 ]]; then
    log "ERROR: no audio files found under ${SHARE_PATH}${FOLDER:+/$FOLDER}"
    rm -f "$AUTH_FILE" "$REMOTE_LIST_FILE"
    exit 1
fi

log "Found ${FILE_COUNT} audio files - starting batch scheduler"

# Stop any previous scheduler before starting a fresh one - a re-Start
# with different config should not leave two schedulers racing to feed
# the same relay port.
if [[ -f "$SCHEDULER_PID_FILE" ]]; then
    kill "$(cat "$SCHEDULER_PID_FILE" 2>/dev/null)" 2>/dev/null || true
    rm -f "$SCHEDULER_PID_FILE"
fi

nohup bash "${HERE}/netshare_batch_scheduler.sh" \
    "$SHARE_PATH" >> "$LOG_FILE" 2>&1 &
SCHEDULER_PID=$!
if ! echo "$SCHEDULER_PID" > "$SCHEDULER_PID_FILE" 2>/dev/null; then
    log "ERROR: could not write $SCHEDULER_PID_FILE - killing untracked scheduler pid=$SCHEDULER_PID"
    kill "$SCHEDULER_PID" 2>/dev/null || true
    exit 1
fi
log "Batch scheduler started pid=$SCHEDULER_PID"

# The scheduler starts the relay itself (first batch, staged
# synchronously below before returning) - wait for it to actually do so
# before handing back to er_start_source.sh, which starts polling the
# relay port immediately after this script returns.
for _ in $(seq 1 200); do
    [[ -f "${STATE_DIR}/relay.pid" ]] && kill -0 "$(cat "${STATE_DIR}/relay.pid" 2>/dev/null)" 2>/dev/null && exit 0
    sleep 0.25
done
log "ERROR: batch scheduler did not start the relay in time"
exit 1
