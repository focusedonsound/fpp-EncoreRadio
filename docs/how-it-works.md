# How Encore Radio Works

## Architecture

Every source converges on PulseAudio:

- **Custom Stream**: any plain HTTP/HTTPS internet radio URL the owner
  types in directly, re-streamed through the same local relay as TuneIn.
- **Network Share**: mounts an existing SMB/CIFS share (`mount.cifs`),
  shuffles the audio files found in the chosen folder into an ffmpeg
  concat playlist, and hands that to the local relay too - `-stream_loop
  -1` makes it loop forever, so it behaves like a continuous station the
  same way a network stream does. Nothing is copied onto the device, so
  the library can be far larger than local storage would allow.
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

## Spotify OAuth redirect bounce

Spotify only accepts an `https://` redirect URI (or an exact `127.0.0.1`
loopback) - a plain LAN address like `http://192.168.x.x` is rejected
outright, and every Encore Radio install has a different LAN address
anyway, so there's no single fixed URL that could point straight at the
device. Instead, every install's Spotify Developer App is configured with
one fixed HTTPS redirect URI pointing at the license server
(`/spotify/callback`). `www/spotify_auth.php` passes the device's own
local callback URL through Spotify's `state` parameter; the license
server's handler does nothing but a plain 302 redirect back to that URL
with the auth `code` appended - the token exchange itself still happens
entirely on the local device (`www/spotify_callback.php`), which never
sends the client secret anywhere but Spotify.

## Source Rotation and Source Fallback (premium)

Both live behind a shared watchdog, `scripts/er_playback_scheduler.sh`,
started alongside the announcement scheduler whenever either is enabled
and the premium gate passes. It polls every 30 seconds:

- **Rotation**: evaluates `rotation.entries` against the current
  day-of-week and time (a fixed weekday index, not locale-dependent
  `strftime`) to find which source should be playing right now. If that
  differs from what's actually playing, it stops the current source and
  starts the new one - both at the initial Start command and continuously
  afterward, so a schedule boundary crossed mid-session actually swaps
  sources rather than only being checked at Start.
- **Fallback**: checks whether the currently active source's playback is
  actually still alive (a PID check for the relay-based sources, a Web
  API device/is_playing check for Spotify, since Raspotify has no local
  process to check). If it's died, it advances to the next entry in
  `fallback.chain` and starts that instead. The same chain-walking also
  runs once synchronously at the initial Start command, in case the
  first choice fails to start at all.

The two features share `scripts/lib_playback_schedule.sh` (the
day/time-matching and chain-walking logic) and `scripts/er_start_source.sh`
/ `scripts/er_stop_playback.sh` (starting/stopping one specific source,
independent of the "real Stop" that also tears down the announcement
scheduler) - both `commands/er_cmd_start.sh` and the watchdog call the
exact same primitives, so there's only one implementation of "what does
starting/stopping Spotify actually involve" to keep correct.

Verified end-to-end on real FPP 10.x hardware: initial source pick for
Rotation, a live mid-session swap triggered by editing the schedule,
Fallback walking from a deliberately-broken Pandora config to TuneIn at
Start, and a live failover triggered by killing `ffplay` mid-play.

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

A custom stream URL, a network share, TuneIn, a single source, and basic
announcement scheduling are always free, no registration. Pandora and Spotify (custom playlists) get a
10-cumulative-hour trial, then require registering an email and entering
a license key - see `docs/configuration.md`.

## License gating

Premium features check for a valid trial or license before starting.
See `docs/configuration.md` for the relevant config fields.
