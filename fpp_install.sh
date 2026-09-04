#!/bin/bash
set -euo pipefail

PLUGIN_NAME="Encore Radio"
PLUGIN_ID="EncoreRadio"

# FPP Plugin Manager may pass these as args like: FPPDIR=/opt/fpp SRCDIR=... PLUGINDIR=...
FPPDIR="${FPPDIR:-}"
SRCDIR="${SRCDIR:-}"
PLUGINDIR="${PLUGINDIR:-}"

CFG_DIR="/home/fpp/media/config"
CFG_FILE="${CFG_DIR}/encoreradio.json"
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

install_pkgs_if_missing() {
  local missing=0
  # ffmpeg: local relay + TuneIn/Pandora re-streaming
  # pianobar: headless Pandora client (premium-tier backend)
  # pulseaudio/pulseaudio-utils/libasound2-plugins: FPP 9.x playback path -
  # NOT installed by FPP itself by default (confirmed on a fresh v9.5 test
  # box - only libpulse0 client libs are present, no server), so this
  # plugin has to be able to stand this up on its own rather than assuming
  # Announcement Assistant already did it.
  # jq/python3: JSON config helpers, matches AA's convention
  # cifs-utils: mount.cifs, for the Network Share (SMB) source
  local pkgs=(ffmpeg pianobar pulseaudio pulseaudio-utils libasound2-plugins curl python3 jq cifs-utils)

  for p in "${pkgs[@]}"; do
    if ! dpkg -s "$p" >/dev/null 2>&1; then
      missing=1
      break
    fi
  done

  if [[ "$missing" -eq 1 ]]; then
    log "Installing required packages (ffmpeg, pianobar, pulseaudio, curl, python3, jq, cifs-utils)…"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends "${pkgs[@]}"
  else
    log "Required packages already installed."
  fi
}

install_raspotify_if_needed() {
  # librespot itself has no prebuilt ARM binaries (checked: GitHub releases
  # ship source only). Raspotify is the standard, maintained Spotify Connect
  # package for Raspberry Pi - a proper .deb, not a random curl|sh script.
  if command -v librespot >/dev/null 2>&1 || dpkg -s raspotify >/dev/null 2>&1; then
    log "Raspotify/librespot already installed."
    # Still needs enabling/starting even when the package is already
    # present - fpp_uninstall.sh deliberately disables (but doesn't
    # remove) the service, so a plain reinstall must re-enable it or
    # Spotify silently stays broken after an uninstall/reinstall cycle
    # (found via real-hardware testing).
    systemctl enable raspotify.service 2>&1 || true
    systemctl start raspotify.service 2>&1 || true
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
  if ! curl -sL -o "$tmp_deb" "$deb_url"; then
    log "WARNING: failed to download Raspotify - Spotify (premium) backend will not work."
    return 0
  fi
  dpkg -i "$tmp_deb" 2>&1 || true
  apt-get install -y -f 2>&1 || true
  rm -f "$tmp_deb"

  if ! command -v librespot >/dev/null 2>&1; then
    log "WARNING: Raspotify install did not complete successfully."
    return 0
  fi

  # Defaults to ALSA; we route everything through PulseAudio (same socket
  # AA ducks / our other backends use) and give it a name our own Web API
  # device lookup can recognize by an exact match.
  local device_name="EncoreRadio-$(hostname)"
  ensure_dir /etc/raspotify
  if [[ -f /etc/raspotify/conf ]]; then
    sed -i -E 's/^#?LIBRESPOT_BACKEND=.*/LIBRESPOT_BACKEND="pulseaudio"/' /etc/raspotify/conf
    if grep -q '^#\?LIBRESPOT_NAME=' /etc/raspotify/conf; then
      sed -i -E "s/^#?LIBRESPOT_NAME=.*/LIBRESPOT_NAME=\"${device_name}\"/" /etc/raspotify/conf
    else
      echo "LIBRESPOT_NAME=\"${device_name}\"" >> /etc/raspotify/conf
    fi
  fi

  # Stored so our own scripts know which Connect device name to look up via
  # the Web API without having to re-read raspotify's own config file.
  python3 -c "
import json
cfg = json.load(open('$CFG_FILE')) if __import__('os').path.exists('$CFG_FILE') else {}
cfg.setdefault('spotify', {})['deviceName'] = '${device_name}'
json.dump(cfg, open('$CFG_FILE', 'w'), indent=2)
" 2>/dev/null || true

  systemctl daemon-reload
  systemctl enable raspotify.service 2>&1 || true
  systemctl restart raspotify.service 2>&1 || true

  log "Raspotify installed - device name: ${device_name}. One-time pairing still needed (see plugin page)."
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
  if [[ -S /run/pulse/native ]]; then
    log "System PulseAudio socket already present (/run/pulse/native) - reusing it."
    return 0
  fi

  log "No system PulseAudio socket found - setting one up."

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

load-module module-native-protocol-unix auth-anonymous=1 socket=/run/pulse/native
load-module module-udev-detect
load-module module-always-sink
load-module module-stream-restore
load-module module-device-restore
load-module module-default-device-restore
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
ExecStart=/usr/bin/pulseaudio --system -nF /etc/pulse/system.pa --disallow-exit --exit-idle-time=-1 --log-target=file:/home/fpp/media/logs/EncoreRadio-pulse.log
ExecStartPost=/bin/sh -c 'chmod 0666 /run/pulse/native || true'
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

  local d="/home/fpp/.config/pulse"
  ensure_dir "$d"
  cat > "${d}/client.conf" <<'EOF'
autospawn = no
default-server = unix:/run/pulse/native
EOF
  chown -R fpp:fpp "/home/fpp/.config" 2>/dev/null || true

  log "System PulseAudio ready at /run/pulse/native"
}

seed_default_config_if_missing() {
  ensure_dir "$CFG_DIR"
  ensure_dir "$STATE_DIR"
  ensure_dir "$LOG_DIR"

  # FPP Commands (and this page's Start/Stop buttons) run as the 'fpp' user,
  # not root - state dir needs to be writable by it or every playback
  # attempt fails on the very first PID-file write (confirmed on real
  # hardware: er_relay.sh couldn't write relay.pid here when the dir was
  # left root-owned).
  chown -R fpp:fpp "$STATE_DIR" 2>/dev/null || true

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
    "key": "",
    "trialSecondsUsed": 0
  },
  "ui": {
    "onboardingSeen": false,
    "onboardingTourEnabled": true
  }
}
EOF
    chown fpp:fpp "$CFG_FILE" 2>/dev/null || true
    chmod 664 "$CFG_FILE" || true
    log "Created default config: $CFG_FILE"
  else
    log "Config already exists: $CFG_FILE"
  fi
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

  install_pkgs_if_missing
  ensure_users_in_audio_group
  setup_system_pulseaudio_if_needed
  seed_default_config_if_missing
  install_raspotify_if_needed
  fix_plugin_script_perms
  post_install_notes

  set +u
  . "${FPPDIR:-/opt/fpp}/scripts/common" 2>/dev/null || true
  set -u
  setSetting restartFlag 1 2>/dev/null || true

  log "Done."
}

main "$@"
