# How Encore Radio Works

## Architecture

Every source converges on PulseAudio:

- **TuneIn**: a direct station stream URL, re-streamed through a local
  `ffmpeg` relay (`scripts/er_relay.sh`) so playback always points at a
  stable local URL regardless of the upstream stream's own reliability.
- **Pandora**: [Pianobar](https://github.com/PromyLOPh/pianobar) plays into
  a dedicated PulseAudio null-sink, whose monitor feeds the same local
  relay.
- **Spotify** (premium, along with Pandora): [Raspotify](https://github.com/dtcooper/raspotify)
  runs as its own permanent system service (not tied to Encore Radio's
  Start/Stop), configured to output directly to PulseAudio. No relay
  involved - Encore Radio just tells the Spotify Web API to start playback
  on it.

Playback is plain PulseAudio (`ffplay`) on both FPP 9.x (native PulseAudio)
and FPP 10.x (PipeWire's `pipewire-pulse` compatibility layer) - this was
originally going to branch on FPP version using FPP 10.x's native
`Play Media` Stream Slot command, but real-hardware testing found that
command's actual implementation only opens local files (`filesrc`), not
network streams, so it can never play a relay URL. PipeWire's pulse-compat
socket handles it identically to FPP 9.x instead, so there's only one
playback path.

## Announcement Assistant integration

If [Announcement Assistant](https://github.com/focusedonsound/fpp-AnnouncementAssistant)
is installed, Encore Radio's own scheduler (`scripts/er_announce_scheduler.sh`)
fires its existing `Play` FPP Command on a cadence or at specific times -
no changes to AA itself. On FPP 9.x, AA's own ducking already reaches
Encore Radio's stream (it ducks whatever's an active PulseAudio
sink-input, not just FPP's own show audio). On FPP 10.x, AA's ducking
instead targets FPP's own Stream Slot 1 specifically, which Encore Radio's
stream never occupies - so on 10.x, Encore Radio ducks its own stream
around the announcement call instead (confirmed on real hardware: without
this, the announcement would have played over the stream at full volume).

## Free vs. premium

TuneIn, a single source, and basic announcement scheduling are always
free, no registration. Pandora and Spotify (custom playlists) get a
10-cumulative-hour trial, then require registering an email and entering
a license key - see `docs/configuration.md`.

## License gating

`scripts/er_premium_gate.sh` checks a license key (validated against the
[license server](https://github.com/focusedonsound/fpp-EncoreRadio-license-server),
with a grace period if it's briefly unreachable) or, absent one,
cumulative trial seconds used so far. `scripts/er_track_usage.sh` records
actual Spotify playback time and reports it to the license server.
