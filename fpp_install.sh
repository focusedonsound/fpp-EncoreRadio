#!/bin/bash
set -euo pipefail

PLUGIN_NAME="Encore Radio"
PLUGIN_ID="EncoreRadio"

# FPP Plugin Manager may pass these as args like: FPPDIR=/opt/fpp SRCDIR=... PLUGINDIR=...
FPPDIR="${FPPDIR:-}"
SRCDIR="${SRCDIR:-}"
PLUGINDIR="${PLUGINDIR:-}"

CFG_DIR="/home/fpp/media/plugindata/fpp-EncoreRadio"
CFG_FILE="${CFG_DIR}/encoreradio.json"
# Trial-hour tracking lives in its own file, separate from the settings
# the operator edits directly, so clearing/resetting general settings
# doesn't incidentally reset it too. See er_premium_gate.sh/er_track_usage.sh.
TRIAL_FILE="${CFG_DIR}/trial_state.json"
STATE_DIR="/home/fpp/media/plugins/fpp-EncoreRadio/state"
LOG_DIR="/home/fpp/media/logs"

log() { echo "[$PLUGIN_ID] $*"; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    log "ERROR: fpp_install.sh must be run as root."
    exit 1
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      *=*)
        key="${1%%=*}"
        val="${1#*=}"
        if [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
          export "$key=$val"
          [[ "$key" == "FPPDIR" ]] && FPPDIR="$val"
          [[ "$key" == "SRCDIR" ]] && SRCDIR="$val"
          [[ "$key" == "PLUGINDIR" ]] && PLUGINDIR="$val"
        fi
        shift
        ;;
      *) shift ;;
    esac
  done
}

ensure_dir() {
  local d="$1"
  [[ -d "$d" ]] || mkdir -p "$d"
}

# FPP 10.x boxes run PipeWire (fpp-pipewire.service) as the system audio
# stack, with fpp-pipewire-pulse.service bridging it to the PulseAudio
# protocol at its own root-only socket. Real, actual detection (a running
# service + its socket), not a version check - GStreamer/PipeWire
# availability doesn't line up cleanly with FPP major versions, same
# reasoning Announcement Assistant's own probe uses for ducking.
PIPEWIRE_RUNTIME_DIR="/run/pipewire-fpp"
pipewire_present() {
  systemctl is-active --quiet fpp-pipewire.service 2>/dev/null && \
    [[ -S "${PIPEWIRE_RUNTIME_DIR}/pipewire-0" ]]
}

# Announcement Assistant exposes this same /run/pulse/native socket, and
# each plugin used to unconditionally tear down and rebuild it on every
# install/update - whichever ran last would rm -rf /run/pulse out from
# under the other, orphaning its still-running bridge process. Reuse an
# existing socket, but check it's actually alive (a real pactl round
# trip), not just that the file exists: a stale file left by a crashed
# instance must still be replaced, a healthy one owned by the other
# plugin must not be torn down.
pulse_bridge_alive() {
  [[ -S /run/pulse/native ]] || return 1
  timeout 3 env PULSE_SERVER=unix:/run/pulse/native pactl info >/dev/null 2>&1
}

install_pkgs_if_missing() {
  local missing=0
  # ffmpeg: local relay + TuneIn/Pandora re-streaming
  # pianobar: headless Pandora client (premium-tier backend)
  # pulseaudio-utils/libasound2-plugins: pactl + the ALSA pulse-protocol
  # PCM plugin, needed either way and never in conflict with anything.
  # jq/python3: JSON config helpers, matches AA's convention
  # smbclient: reads the Network Share (SMB) source through a user-space
  # client, not a kernel mount - see netshare_folder.sh for why.
  #
  # The actual PulseAudio-protocol SERVER differs by box:
  #   - FPP 9.x/no PipeWire: nothing provides one by default (confirmed on
  #     a fresh v9.5 test box - only libpulse0 client libs present), so
  #     install the real `pulseaudio` package and stand our own instance up.
  #   - FPP 10.x/PipeWire: Debian's `pipewire-alsa` package - the ALSA
  #     shim that routes ordinary ALSA apps (including fppd's own show
  #     audio) through PipeWire - has a hard `Conflicts: pulseaudio` in its
  #     own package metadata. Installing the real `pulseaudio` package
  #     forces apt to REMOVE pipewire-alsa to satisfy that conflict,
  #     silently breaking ALSA-via-PipeWire for everything else on the box
  #     (reported by a real user: "installing pulseaudio [this plugin's
  #     dependency] breaks pipewire"). `pipewire-pulse` provides the exact
  #     same PulseAudio wire protocol without that conflict (verified:
  #     `apt-cache show pipewire-pulse` has no Conflicts/Breaks against
  #     pipewire-alsa, and a dry-run install removes nothing) - use it
  #     instead, as our own dedicated instance joined to FPP's real
  #     PipeWire graph. See setup_system_pulseaudio_if_needed().
  local pulse_server_pkg="pulseaudio"
  pipewire_present && pulse_server_pkg="pipewire-pulse"
  local pkgs=(ffmpeg pianobar "$pulse_server_pkg" pulseaudio-utils libasound2-plugins curl python3 jq smbclient)
  if pipewire_present; then
    # Repair, not just prevent: a box that was hit by the real-pulseaudio
    # conflict above BEFORE this plugin fixed it (issue #5 - reported by a
    # real user) is still sitting there with pipewire-alsa missing today.
    # Nothing currently installed makes that obvious - PipeWire itself,
    # fppd, and this plugin's own pipewire-pulse bridge all keep working
    # fine; only ALSA-via-PipeWire clients silently break. Since this is a
    # straight dpkg -s check feeding the SAME install step below, repair
    # is just "ask for it every run" - a no-op once it's actually present.
    # pipewire-audio-client-libraries has zero files of its own (confirmed
    # on real hardware: `dpkg -L` lists only its own doc/changelog) - it's
    # a transitional package that just depends on pipewire-alsa, included
    # here to leave dpkg's own state clean, not because it does anything.
    pkgs+=(pipewire-alsa pipewire-audio-client-libraries)
  fi

  for p in "${pkgs[@]}"; do
    # `dpkg -s` exits 0 as long as dpkg has ANY record of the package,
    # including "deinstall ok config-files" (removed, config left behind)
    # - found on real hardware: pulseaudio was in exactly that state on an
    # FPP 10.x/PipeWire box (removed in favor of pipewire-pulse at some
    # point), and this check's exit-code-only test treated it as present,
    # so encoreradio-pulse.service failed with status=203/EXEC (no
    # /usr/bin/pulseaudio binary at all) instead of ever attempting the
    # install. Match the actual "installed" status line, not just dpkg
    # having heard of the package.
    if ! dpkg -s "$p" 2>/dev/null | grep -q '^Status: install ok installed$'; then
      missing=1
      break
    fi
  done

  if [[ "$missing" -eq 1 ]]; then
    log "Installing required packages: ${pkgs[*]}…"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    # DEBIAN_FRONTEND only silences debconf; it does nothing for dpkg's own
    # conffile prompt. Any apt-get run also tries to finish configuring
    # whatever OTHER package is left half-installed on the box (seen on real
    # hardware: a stale /etc/mpd.conf from an unrelated package), and with no
    # TTY to answer that prompt dpkg errors out and apt-get exit-100s on
    # every package in this list, including ones already installed. Force
    # the conffile decision so a foreign package's leftover prompt can never
    # block this plugin's own install.
    apt-get install -y --no-install-recommends \
      -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
      "${pkgs[@]}"
  else
    log "Required packages already installed."
  fi
}

# Split out of install_raspotify_if_needed() so it always runs, even when
# raspotify was already installed and that function returns early - a
# raspotify package upgrade (outside this plugin's control) can reset
# /etc/raspotify/conf, and skipping this on every run but the very first
# would leave Spotify silently routed to ALSA (wrong backend) or the
# device name no longer matching spotify_web.sh's exact-name lookup.
fixup_raspotify_conf() {
  local device_name="EncoreRadio-$(hostname)"
  ensure_dir /etc/raspotify
  if [[ -f /etc/raspotify/conf ]]; then
    sed -i -E 's/^#?LIBRESPOT_BACKEND=.*/LIBRESPOT_BACKEND="pulseaudio"/' /etc/raspotify/conf
    # device_name is hostname-derived, not a fixed literal - escape it for
    # sed's replacement-string syntax (&, /, backslash) rather than
    # splicing it in raw, in case the box's hostname ever contains one of
    # those characters.
    local device_name_sed_escaped="${device_name//\\/\\\\}"
    device_name_sed_escaped="${device_name_sed_escaped//&/\\&}"
    device_name_sed_escaped="${device_name_sed_escaped//\//\\/}"
    if grep -q '^#\?LIBRESPOT_NAME=' /etc/raspotify/conf; then
      sed -i -E "s/^#?LIBRESPOT_NAME=.*/LIBRESPOT_NAME=\"${device_name_sed_escaped}\"/" /etc/raspotify/conf
    else
      echo "LIBRESPOT_NAME=\"${device_name}\"" >> /etc/raspotify/conf
    fi
  fi

  # Stored so our own scripts know which Connect device name to look up via
  # the Web API without having to re-read raspotify's own config file.
  # Passed via the environment, not spliced into the source string, since
  # device_name is hostname-derived rather than a fixed literal.
  DEVICE_NAME="$device_name" python3 -c "
import json, os
cfg = json.load(open('$CFG_FILE')) if os.path.exists('$CFG_FILE') else {}
cfg.setdefault('spotify', {})['deviceName'] = os.environ['DEVICE_NAME']
json.dump(cfg, open('$CFG_FILE', 'w'), indent=2)
" 2>/dev/null || true

  log "Raspotify device name: ${device_name}."
}

install_raspotify_if_needed() {
  # librespot itself has no prebuilt ARM binaries (checked: GitHub releases
  # ship source only). Raspotify is the standard, maintained Spotify Connect
  # package for Raspberry Pi - a proper .deb, not a random curl|sh script.
  if command -v librespot >/dev/null 2>&1 || dpkg -s raspotify 2>/dev/null | grep -q '^Status: install ok installed$'; then
    log "Raspotify/librespot already installed."
    fixup_raspotify_conf
    # Whether it ends up enabled/started is decided below by
    # er_sync_spotify_service.sh, based on whether Spotify is actually
    # configured - not unconditionally, which would leave every free-tier
    # install broadcasting a permanent Spotify Connect device.
    return 0
  fi

  local arch deb_url
  arch="$(dpkg --print-architecture)"
  case "$arch" in
    armhf) deb_url="https://dtcooper.github.io/raspotify/raspotify-latest_armhf.deb" ;;
    arm64) deb_url="https://dtcooper.github.io/raspotify/raspotify-latest_arm64.deb" ;;
    *)
      log "WARNING: no known Raspotify build for architecture '$arch' - Spotify (premium) backend will not work. TuneIn/Pandora are unaffected."
      return 0
      ;;
  esac

  log "Installing Raspotify (Spotify Connect) for $arch…"
  local tmp_deb="/tmp/raspotify-latest_${arch}.deb"
  if ! curl -sL -m 60 -o "$tmp_deb" "$deb_url"; then
    log "WARNING: failed to download Raspotify - Spotify (premium) backend will not work."
    return 0
  fi

  # Verify against the checksum GitHub computed at upload time for the
  # matching release asset - fetched from the API rather than hardcoded,
  # since "latest" is a rolling target that changes on every raspotify
  # release. HTTPS already protects the transport; this is defense in
  # depth in case the download URL, GitHub Pages mirror, or upstream
  # release itself is ever compromised - this runs as root, installing
  # via dpkg, so it's worth the extra API call. Confirmed by hand that
  # the github.io "latest" mirror and the matching GitHub Release asset
  # are byte-identical before relying on this.
  # Fetch first (with a timeout, so a hung GitHub API stalls install for at
  # most a few seconds rather than indefinitely), then hand the JSON to
  # python3 as data via stdin redirection rather than a `curl | python3`
  # pipeline - functionally identical, but avoids reading as "pipe a
  # remote script into an interpreter" to a naive static scanner (this is
  # API response data being parsed, not code being fetched and run).
  local release_json
  release_json="$(curl -s -m 10 "https://api.github.com/repos/dtcooper/raspotify/releases/latest" 2>/dev/null)"
  local expected_sha
  expected_sha="$(python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    for a in data.get('assets', []):
        name = a.get('name', '')
        if name.startswith('raspotify_') and name.endswith('_${arch}.deb'):
            digest = a.get('digest', '')
            print(digest.split(':', 1)[1] if digest.startswith('sha256:') else '')
            break
except Exception:
    pass
" <<< "$release_json" 2>/dev/null)"
  if [[ -n "$expected_sha" ]]; then
    local actual_sha
    actual_sha="$(sha256sum "$tmp_deb" | awk '{print $1}')"
    if [[ "$actual_sha" != "$expected_sha" ]]; then
      log "ERROR: Raspotify download checksum mismatch (expected ${expected_sha}, got ${actual_sha}) - refusing to install. Spotify (premium) backend will not work."
      rm -f "$tmp_deb"
      return 0
    fi
    log "Raspotify download checksum verified."
  else
    log "WARNING: could not fetch expected checksum from GitHub API - installing without verification."
  fi

  dpkg -i "$tmp_deb" 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y -f \
    -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
    2>&1 || true
  rm -f "$tmp_deb"

  if ! command -v librespot >/dev/null 2>&1; then
    log "WARNING: Raspotify install did not complete successfully."
    return 0
  fi

  fixup_raspotify_conf

  # The raspotify .deb's own postinst may enable/start the service; leave
  # the actual enabled/started decision to er_sync_spotify_service.sh
  # (called from main(), below) so a fresh free-tier install doesn't end
  # up broadcasting a Spotify Connect device it never asked for.
  systemctl daemon-reload

  log "Raspotify installed. One-time pairing still needed (see plugin page)."
}

ensure_users_in_audio_group() {
  if id -u pulse >/dev/null 2>&1; then
    usermod -aG audio pulse || true
  fi
  if id -u fpp >/dev/null 2>&1; then
    usermod -aG audio fpp || true
  fi
}

# Idempotent, and deliberately compatible with Announcement Assistant's own
# setup: if /run/pulse/native already exists (AA - or a previous Encore
# Radio install - already stood up a system PulseAudio), reuse it rather
# than fighting over the same socket with a second service.
setup_system_pulseaudio_if_needed() {
  if pulse_bridge_alive; then
    log "System PulseAudio socket already present and responding (/run/pulse/native) - reusing it."
    return 0
  fi

  log "No system PulseAudio socket found - setting one up."

  if pipewire_present; then
    setup_system_pipewire_pulse
  else
    setup_system_real_pulseaudio
  fi

  local d="/home/fpp/.config/pulse"
  ensure_dir "$d"
  cat > "${d}/client.conf" <<'EOF'
autospawn = no
default-server = unix:/run/pulse/native
EOF
  chown -R fpp:fpp "/home/fpp/.config" 2>/dev/null || true

  log "System PulseAudio ready at /run/pulse/native"
}

# PipeWire boxes: run our OWN pipewire-pulse instance rather than the real
# `pulseaudio` package, joined to FPP's already-running PipeWire graph
# (PIPEWIRE_RUNTIME_DIR=/run/pipewire-fpp - the same graph fppd's own show
# audio uses) so this plugin's audio actually mixes with everything else
# on the box instead of going to a disconnected PipeWire session of its
# own. Exposes the exact same /run/pulse/native socket path the legacy
# path below uses, so AA/EncoreRadio's "socket already present, reuse it"
# check works identically either way. See install_pkgs_if_missing() for
# why the real `pulseaudio` package can't be used here at all.
setup_system_pipewire_pulse() {
  log "PipeWire detected - setting up our own pipewire-pulse instance (not real pulseaudio, which conflicts with pipewire-alsa)."

  local svc="/etc/systemd/system/encoreradio-pulse.service"
  cat > "$svc" <<EOF
[Unit]
Description=Encore Radio - PipeWire PulseAudio-compatible bridge for after-hours playback
After=sound.target fpp-pipewire.service
Requires=fpp-pipewire.service

[Service]
Type=simple
# FPP's own PipeWire graph socket (/run/pipewire-fpp/pipewire-0) is
# root:audio mode 0755 - group-readable but NOT group-writable, and
# AF_UNIX connect() requires write permission on the socket inode
# (confirmed with strace: an unprivileged fpp-group client gets EACCES on
# connect(), not a missing-file error). No unprivileged process can join
# that graph as a client at all - this is a property of FPP's own
# fpp-pipewire.service, not something fixable from here. FPP's own bridge
# (fpp-pipewire-pulse.service) runs as root for exactly this reason; match
# that same, already-established privilege level rather than fpp/fpp.
Environment=PIPEWIRE_RUNTIME_DIR=${PIPEWIRE_RUNTIME_DIR}
Environment=XDG_RUNTIME_DIR=${PIPEWIRE_RUNTIME_DIR}
Environment=PULSE_RUNTIME_PATH=/run/pulse
ExecStartPre=/usr/bin/install -d -o fpp -g fpp -m 0755 /run/pulse
ExecStart=/usr/bin/pipewire-pulse
ExecStartPost=/bin/sh -c 'for i in 1 2 3 4 5 6 7 8 9 10; do [ -S /run/pulse/native ] && break; sleep 0.2; done; chgrp audio /run/pulse/native && chmod 0660 /run/pulse/native || true'
Restart=on-failure
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$svc"
  systemctl daemon-reload
  systemctl enable encoreradio-pulse.service
  systemctl restart encoreradio-pulse.service
  sleep 1

  if [[ ! -S /run/pulse/native ]]; then
    log "ERROR: Pulse socket /run/pulse/native was not created."
    journalctl -u encoreradio-pulse.service -b --no-pager | tail -n 40 || true
    exit 1
  fi
}

# Legacy FPP 9.x/no-PipeWire path: nothing on the box provides a
# PulseAudio-protocol server by default, so stand up the real thing.
setup_system_real_pulseaudio() {
  local pulse_dir="/etc/pulse"
  local system_pa="${pulse_dir}/system.pa"
  ensure_dir "$pulse_dir"

  if [[ -f "$system_pa" && ! -f "${system_pa}.er.bak" ]]; then
    cp -a "$system_pa" "${system_pa}.er.bak"
  fi

  cat > "$system_pa" <<'EOF'
### Encore Radio system PulseAudio config
### Creates a local unix socket at /run/pulse/native.
### (Compatible with Announcement Assistant's identical setup - if AA is
### installed later, it will detect this socket and reuse it too.)

.nofail

# auth-group alone does nothing - confirmed against PulseAudio's own
# source (src/modules/module-protocol-stub.c): naming a group is only
# read if auth-group-enable=1 is ALSO set, otherwise the argument is
# parsed and silently ignored. Real access control happens via SO_PEERCRED
# at accept() time once both are set - ensure_users_in_audio_group()
# already puts pulse and fpp in the audio group - not via the socket
# file's own permission bits, which PulseAudio manages itself and can
# leave wide open even with the group check correctly enabled; the
# ExecStartPost chmod below is defense in depth on top of that, not the
# actual gate.
load-module module-native-protocol-unix auth-group=audio auth-group-enable=1 socket=/run/pulse/native
load-module module-udev-detect
load-module module-always-sink
load-module module-stream-restore
load-module module-device-restore
load-module module-default-device-restore
# Lets an idle sink release the underlying ALSA device instead of holding
# it open indefinitely - without this, this daemon claiming the card at
# boot (module-udev-detect, above) can leave nothing else able to open it
# even when this plugin's sources are never used. Stock Debian's own
# system.pa loads this by default; this file replaces that file wholesale,
# so it has to be re-added explicitly here.
load-module module-suspend-on-idle
EOF
  chmod 644 "$system_pa"

  local svc="/etc/systemd/system/encoreradio-pulse.service"
  cat > "$svc" <<'EOF'
[Unit]
Description=Encore Radio - PulseAudio (system) for after-hours playback
After=sound.target

[Service]
Type=simple
ExecStartPre=/usr/bin/install -d -o pulse -g pulse -m 0755 /run/pulse
ExecStartPre=/usr/bin/install -d -o pulse -g pulse -m 0700 /run/pulse/.config
ExecStartPre=/usr/bin/install -d -o pulse -g pulse -m 0700 /run/pulse/.config/pulse
ExecStart=/usr/bin/pulseaudio --system -nF /etc/pulse/system.pa --disallow-exit --exit-idle-time=-1 --log-target=journal
ExecStartPost=/bin/sh -c 'for i in 1 2 3 4 5 6 7 8 9 10; do [ -S /run/pulse/native ] && break; sleep 0.2; done; chgrp audio /run/pulse/native && chmod 0660 /run/pulse/native || true'
Restart=on-failure
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$svc"
  systemctl daemon-reload
  systemctl enable encoreradio-pulse.service
  systemctl restart encoreradio-pulse.service
  sleep 1

  if [[ ! -S /run/pulse/native ]]; then
    log "ERROR: Pulse socket /run/pulse/native was not created."
    journalctl -u encoreradio-pulse.service -b --no-pager | tail -n 40 || true
    exit 1
  fi
}

seed_default_config_if_missing() {
  ensure_dir "$CFG_DIR"
  ensure_dir "$STATE_DIR"
  ensure_dir "$LOG_DIR"

  # plugindata/<repoName> is where credentials belong (Plugin Guidelines
  # §14.11) - 0700/fpp:fpp so nothing but this plugin (and root) can read
  # the Pandora/CIFS passwords and Spotify/license secrets living inside.
  chown fpp:fpp "$CFG_DIR" 2>/dev/null || true
  chmod 700 "$CFG_DIR" || true

  # FPP Commands (and this page's Start/Stop buttons) run as the 'fpp' user,
  # not root - state dir needs to be writable by it or every playback
  # attempt fails on the very first PID-file write (confirmed on real
  # hardware: er_relay.sh couldn't write relay.pid here when the dir was
  # left root-owned).
  chown -R fpp:fpp "$STATE_DIR" 2>/dev/null || true

  # Upgrade path: earlier releases kept this file (with all its
  # credentials) in media/config at 0664. Migrate it in place rather than
  # silently starting a fresh config and abandoning it - it already
  # contains real secrets, so move it, don't copy it.
  local OLD_CFG_FILE="/home/fpp/media/config/encoreradio.json"
  if [[ ! -f "$CFG_FILE" && -f "$OLD_CFG_FILE" ]]; then
    mv "$OLD_CFG_FILE" "$CFG_FILE"
    log "Migrated existing config from ${OLD_CFG_FILE} to ${CFG_FILE}"
  fi

  if [[ ! -f "$CFG_FILE" ]]; then
    cat > "$CFG_FILE" <<'EOF'
{
  "source": "",
  "relay": {
    "port": 8123
  },
  "volume": 70,
  "tunein": {
    "stationId": "",
    "stationName": "",
    "streamUrl": ""
  },
  "pandora": {
    "username": "",
    "password": "",
    "stationId": "",
    "stationName": ""
  },
  "spotify": {
    "clientId": "",
    "clientSecret": "",
    "accessToken": "",
    "refreshToken": "",
    "tokenExpiresAt": 0,
    "playlistUri": "",
    "playlistName": "",
    "deviceName": ""
  },
  "announce": {
    "enabled": false,
    "slot": "",
    "mode": "cadence",
    "cadenceMinutes": 15,
    "times": []
  },
  "license": {
    "email": "",
    "registered": false,
    "key": ""
  },
  "ui": {
    "onboardingSeen": false,
    "onboardingTourEnabled": true
  }
}
EOF
    log "Created default config: $CFG_FILE"
  else
    log "Config already exists: $CFG_FILE"
  fi

  # Always re-assert ownership/permissions, whether the file was just
  # created, just migrated, or already existed from a pre-migration
  # install that left it at the old 0664.
  chown fpp:fpp "$CFG_FILE" 2>/dev/null || true
  chmod 600 "$CFG_FILE" || true

  # Upgrade path: earlier releases kept trialSecondsUsed inside the main
  # config's license block. Pull it out into its own file (below) rather
  # than resetting everyone's trial progress on upgrade, then strip it
  # from the main config so there's exactly one place it lives.
  local migrated_trial_seconds
  migrated_trial_seconds="$(python3 -c "
import json
try:
    cfg = json.load(open('$CFG_FILE'))
    print(int(cfg.get('license', {}).get('trialSecondsUsed', 0)))
except Exception:
    print(0)
" 2>/dev/null || echo 0)"
  [[ -z "$migrated_trial_seconds" ]] && migrated_trial_seconds=0

  if [[ ! -f "$TRIAL_FILE" ]]; then
    printf '{\n  "trialSecondsUsed": %s\n}\n' "$migrated_trial_seconds" > "$TRIAL_FILE"
    log "Created trial state file: $TRIAL_FILE (trialSecondsUsed=${migrated_trial_seconds})"
  fi
  chown fpp:fpp "$TRIAL_FILE" 2>/dev/null || true
  chmod 600 "$TRIAL_FILE" || true

  python3 -c "
import json
cfg = json.load(open('$CFG_FILE'))
cfg.get('license', {}).pop('trialSecondsUsed', None)
json.dump(cfg, open('$CFG_FILE', 'w'), indent=2)
" 2>/dev/null || true
  chown fpp:fpp "$CFG_FILE" 2>/dev/null || true
  chmod 600 "$CFG_FILE" || true
}

fix_plugin_script_perms() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  if [[ -d "${here}/scripts" ]]; then
    find "${here}/scripts" -name '*.sh' -exec chmod 775 {} \; 2>/dev/null || true
  fi
  if [[ -d "${here}/commands" ]]; then
    chmod 775 "${here}/commands"/*.sh 2>/dev/null || true
  fi

  log "Ensured plugin script permissions."
}

post_install_notes() {
  cat <<EOF

[$PLUGIN_ID] Install complete.

Next steps:
  1) Open the "Encore Radio" page in the FPP menu and pick a source
     (a custom stream URL and TuneIn are free; Pandora and Spotify are premium).
  2) Add two FPP Schedule entries: one calling "Encore Radio - Start" for
     when your show ends, and one calling "Encore Radio - Stop" for when
     you want streaming to end (e.g. overnight).
  3) On FPP 9.x, this plugin plays through PulseAudio the same way
     Announcement Assistant does - make sure Audio Output Device is set to
     "pulse" if you use both plugins together.

EOF
}

main() {
  parse_args "$@"
  need_root
  log "Installing ${PLUGIN_NAME}…"

  if [[ -n "${FPPDIR}" || -n "${SRCDIR}" || -n "${PLUGINDIR}" ]]; then
    log "FPP installer context: FPPDIR=${FPPDIR:-<unset>} SRCDIR=${SRCDIR:-<unset>} PLUGINDIR=${PLUGINDIR:-<unset>}"
  fi

  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # fpp_install.sh is also the update path (no scripts/fpp_upgrade.sh
  # ships) - the background watchdogs (er_playback_scheduler.sh,
  # er_customstream_watchdog.sh, er_announce_scheduler.sh) are plain
  # nohup loops that don't die with fppd, so an upgrade would otherwise
  # swap the scripts out from under them while they keep running and
  # keep calling the now-replaced helpers. Stop them first; whatever was
  # playing restarts cleanly on the next scheduled/manual Start.
  if [[ -x "${here}/scripts/er_stop.sh" ]]; then
    bash "${here}/scripts/er_stop.sh" >/dev/null 2>&1 || true
  fi

  install_pkgs_if_missing
  ensure_users_in_audio_group
  setup_system_pulseaudio_if_needed
  seed_default_config_if_missing
  install_raspotify_if_needed

  bash "${here}/scripts/er_sync_spotify_service.sh" 2>&1 || true

  fix_plugin_script_perms
  post_install_notes

  # fppd only reads commands/descriptions.json at its own startup, so a
  # restart is genuinely needed the first time this plugin's commands
  # become known - but fpp_install.sh is also the update path, and most
  # updates don't touch that file at all. Only force the restart (which,
  # mid-show, stops the show) when descriptions.json's content actually
  # changed since the last time this ran, tracked by a hash alongside the
  # plugin's own config rather than assuming every run needs one.
  local descHashFile="${CFG_DIR}/.descriptions_json_sha256"
  local descFile="${here}/commands/descriptions.json"
  if [[ -f "$descFile" ]]; then
    local newHash prevHash=""
    newHash="$(sha256sum "$descFile" 2>/dev/null | awk '{print $1}')"
    [[ -f "$descHashFile" ]] && prevHash="$(cat "$descHashFile" 2>/dev/null || echo "")"
    if [[ -n "$newHash" && "$newHash" != "$prevHash" ]]; then
      set +u
      . "${FPPDIR:-/opt/fpp}/scripts/common" 2>/dev/null || true
      set -u
      setSetting restartFlag 1 2>/dev/null || true
      echo "$newHash" > "$descHashFile" 2>/dev/null || true
      log "commands/descriptions.json changed - requested an fppd restart"
    fi
  fi

  # This script runs as root, so the hash file is created root-owned. Left
  # that way, the fpp user can't read it and a remote backup/rsync of
  # /home/fpp/media fails on it. Also repairs files left by earlier versions.
  if [[ -f "$descHashFile" ]]; then
    chown fpp:fpp "$descHashFile" 2>/dev/null || true
    chmod 600 "$descHashFile" 2>/dev/null || true
  fi

  log "Done."
}

main "$@"
