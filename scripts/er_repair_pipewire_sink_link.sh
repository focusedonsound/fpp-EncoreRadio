#!/usr/bin/env bash
# Encore Radio - repair a missing PipeWire FX-chain -> hardware sink link.
#
# Works around an FPP core bug (filed upstream:
# https://github.com/FalconChristmas/fpp/issues/3021), not anything this
# plugin itself does wrong. FPP's own PipeWire session wires up a
# "Delay: <card>" filter-chain in front of the real ALSA hardware sink
# (fpp_fx_g<N>_<card>_out -> fpp_alsa_<card>), but the one-shot
# node.target link request that's supposed to connect them can race the
# hardware adapter's own startup and silently never complete - confirmed
# on real hardware, reproducible after a plain reboot, not just a
# cold/first boot. When that happens, fppd's own show audio AND every
# plugin's audio (this one included) plays into a PipeWire graph that
# dead-ends before ever reaching the speaker - no error anywhere, the
# relay/ffplay/sink-input all look completely healthy.
#
# This is additive-only: it only ever creates a link that's missing, by
# name, never removes or rearranges anything already in the graph. A
# healthy box (the common case) costs one pw-dump parse and does nothing.
# Fixing it here (called from er_play_pulse.sh, the one playback path
# every source in this plugin goes through) also fixes it for fppd's own
# show audio and every other plugin sharing the same hardware sink, since
# they all dead-end at the identical missing link - not just ours.
#
# Must run as root: the PipeWire graph's own control socket
# (/run/pipewire-fpp/pipewire-0) is root:audio, group-READ only - not
# group-write - so no unprivileged process can open a client connection
# to it at all (confirmed with strace against the EACCES). Both callers
# of this script already run as root (er_play_pulse.sh is only ever
# reached via fppd's own Command execution).

set -uo pipefail

LOG_FILE="${MEDIADIR:-/home/fpp/media}/logs/plugin-fpp-EncoreRadio.log"
PIPEWIRE_RUNTIME_DIR="/run/pipewire-fpp"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [pw-link-repair] $*" >> "$LOG_FILE"; }

if [[ ! -S "${PIPEWIRE_RUNTIME_DIR}/pipewire-0" ]]; then
    exit 0
fi
command -v pw-dump >/dev/null 2>&1 || exit 0
command -v pw-link >/dev/null 2>&1 || exit 0

DUMP="$(env PIPEWIRE_RUNTIME_DIR="$PIPEWIRE_RUNTIME_DIR" XDG_RUNTIME_DIR="$PIPEWIRE_RUNTIME_DIR" pw-dump 2>/dev/null)"
[[ -z "$DUMP" ]] && exit 0

# Figure out which links are missing, print one "src:port dst:port" pair
# per line - the shell loop below does the actual pw-link calls, so a
# link failure doesn't abort the python side partway through finding the
# rest.
TO_LINK="$(echo "$DUMP" | python3 -c "
import json, re, sys

try:
    objs = json.load(sys.stdin)
except Exception:
    sys.exit(0)

nodes = {}       # id -> name
node_class = {}  # id -> media.class
ports = {}       # id -> (node_id, port_name, direction)
linked_pairs = set()  # (out_port_id, in_port_id) already connected

for o in objs:
    t = o.get('type', '')
    info = o.get('info') or {}
    props = info.get('props') or {}
    if t == 'PipeWire:Interface:Node':
        name = props.get('node.name', '')
        nodes[o['id']] = name
        node_class[o['id']] = props.get('media.class', '')
    elif t == 'PipeWire:Interface:Port':
        ports[o['id']] = (props.get('node.id'), props.get('port.name', ''), props.get('port.direction', ''))
    elif t == 'PipeWire:Interface:Link':
        op, ip = info.get('output-port-id'), info.get('input-port-id')
        if op is not None and ip is not None:
            linked_pairs.add((op, ip))

# Hardware sinks this plugin's/FPP's own session convention creates:
# fpp_alsa_<cardId>, media.class Audio/Sink.
alsa_sinks = {nid: name for nid, name in nodes.items()
              if node_class.get(nid) == 'Audio/Sink' and name.startswith('fpp_alsa_')}

for sink_id, sink_name in alsa_sinks.items():
    card_id = sink_name[len('fpp_alsa_'):]
    if not card_id:
        continue
    # The FX chain's own output node for this exact card - see
    # buildSimplePipeWireGroupsConf()/GeneratePipeWireGroupsConfig() in
    # FPP core (src/boot/FPPINIT_Audio.cpp / www/api/controllers/
    # pipewire.php): node.name = \"fpp_fx_g<N>_<cardId>_out\".
    fx_pattern = re.compile(r'^fpp_fx_g\d+_' + re.escape(card_id) + r'_out$')
    fx_id = next((nid for nid, name in nodes.items() if fx_pattern.match(name)), None)
    if fx_id is None:
        continue  # no FX chain for this card - nothing we can repair

    sink_in_ports = {pname.rsplit('_', 1)[-1]: pid
                     for pid, (nid, pname, direction) in ports.items()
                     if nid == sink_id and direction == 'in'}
    fx_out_ports = {pname.rsplit('_', 1)[-1]: pid
                    for pid, (nid, pname, direction) in ports.items()
                    if nid == fx_id and direction == 'out'}

    for channel, fx_port_id in fx_out_ports.items():
        sink_port_id = sink_in_ports.get(channel)
        if sink_port_id is None:
            continue
        if (fx_port_id, sink_port_id) in linked_pairs:
            continue  # already connected
        fx_port_name = ports[fx_port_id][1]
        sink_port_name = ports[sink_port_id][1]
        print(f'{nodes[fx_id]}:{fx_port_name} {sink_name}:{sink_port_name}')
" 2>/dev/null)"

[[ -z "$TO_LINK" ]] && exit 0

REPAIRED=0
while IFS=' ' read -r src dst; do
    [[ -z "$src" ]] && continue
    if env PIPEWIRE_RUNTIME_DIR="$PIPEWIRE_RUNTIME_DIR" XDG_RUNTIME_DIR="$PIPEWIRE_RUNTIME_DIR" \
        pw-link "$src" "$dst" >/dev/null 2>&1; then
        log "Linked ${src} -> ${dst} (FPP core PipeWire routing gap - https://github.com/FalconChristmas/fpp/issues/3021)"
        REPAIRED=1
    else
        log "WARNING: pw-link ${src} -> ${dst} failed"
    fi
done <<< "$TO_LINK"

[[ "$REPAIRED" -eq 1 ]] && exit 0
exit 1
