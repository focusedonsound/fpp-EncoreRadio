# Troubleshooting

Check `/home/fpp/media/logs/EncoreRadio.log` first - every script writes
timestamped, tagged lines there (`[er_relay]`, `[pulse-play]`, `[spotify]`,
`[announce]`, `[premium-gate]`, `[usage]`, etc.).

## Nothing plays after "Encore Radio - Start"

- Check the log for the actual error - `tunein_stream.sh`/
  `pandora_pianobar.sh`/`spotify_web.sh` all log a clear reason before
  exiting (no station configured, bad credentials, device not paired, ...).
- Confirm a source is actually selected and saved on the plugin page.
- For TuneIn/Pandora: `pactl list sink-inputs` should show an `ffplay`
  entry once playback starts. If it doesn't, PulseAudio itself may not be
  running - check `systemctl status encoreradio-pulse.service` (or
  `announcementassistant-pulse.service` if Announcement Assistant is also
  installed; whichever installed second owns the shared socket - see
  below).

## Announcements aren't ducking the stream

- Confirm Announcement Assistant is actually installed and a slot has a
  real audio file configured.
- On FPP 10.x specifically: check the log for a "Self-ducking our stream"
  line right before "Firing Announcement Assistant". If it's missing,
  the `Media Slot Status` probe (`scripts/er_announce_scheduler.sh`) may
  not be detecting FPP 10.x correctly.
- On FPP 9.x: AA's own ducking should reach the stream automatically - if
  it doesn't, check that FPP's Audio Output Device is set to `pulse` and
  that AA's own PulseAudio setup succeeded.

## Encore Radio and Announcement Assistant fighting over PulseAudio

Both plugins can stand up their own system-wide PulseAudio service
(`encoreradio-pulse.service` / `announcementassistant-pulse.service`) if
neither exists yet, but each checks for `/run/pulse/native` first and
reuses it if already present - so in practice only one service ends up
actually running PulseAudio, whichever installed second. This is expected
and not a conflict by itself, but it does mean **uninstalling whichever
plugin currently owns that service will silently break the other's audio**
too. If that happens, reinstalling either plugin re-creates the shared
PulseAudio service.

## Spotify: "device not found" / "has it been paired yet?"

This means the Raspotify Connect device isn't currently visible to the
Spotify Web API. Open Spotify on your phone (same network as the FPP box)
and select the device name shown on the Encore Radio page from the
Connect/devices list. Also confirm `raspotify.service` is actually running
(`systemctl status raspotify.service`).

## Pandora/Spotify: playback works but stops after the trial

Expected - Pandora and Spotify are both premium, gated behind a shared
10-cumulative-hour trial (or a valid license key). Register on the Encore
Radio page and enter a license key once you have one. TuneIn is
unaffected; it's never gated.

## Relay port already in use / stale process

`scripts/er_relay.sh` tracks its own PID and hardens against leaving an
orphaned `ffmpeg` process on a failed start, but if something outside the
plugin's own lifecycle killed a process uncleanly, check
`ps aux | grep ffmpeg` and `cat /home/fpp/media/plugins/fpp-EncoreRadio/state/relay.pid`
- if they don't match, kill the stray process manually and run
"Encore Radio - Stop" once to clear plugin state.
