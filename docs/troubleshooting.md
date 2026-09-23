# Troubleshooting

Check `/home/fpp/media/logs/plugin-fpp-EncoreRadio.log` first - every script writes
timestamped, tagged lines there (`[er_relay]`, `[pulse-play]`, `[spotify]`,
`[announce]`, `[premium-gate]`, `[usage]`, etc.).

## Nothing plays after "Encore Radio - Start"

- Check the log for the actual error - `customstream_stream.sh`/
  `netshare_folder.sh`/`tunein_stream.sh`/`pandora_pianobar.sh`/
  `spotify_web.sh` all log a clear reason before exiting (no station/URL
  configured, bad credentials, device not paired, ...).
- Confirm a source is actually selected and saved on the plugin page.
- For custom stream/TuneIn/Pandora: `pactl list sink-inputs` should show an `ffplay`
  entry once playback starts. If it doesn't, PulseAudio itself may not be
  running - check `systemctl status encoreradio-pulse.service` (or
  `announcementassistant-pulse.service` if Announcement Assistant is also
  installed; whichever installed second owns the shared socket - see
  below).

## Network Share: "failed to mount" or "no audio files found"

- Confirm the share path is exactly right - `//192.168.1.50/Music`, not a
  `smb://` URL or a Windows-style `\\` path.
- Try mounting it manually to get the real error: `sudo mount -t cifs
  "//host/share" /mnt -o username=...,password=...` (or `-o guest` with no
  username configured) - `mount.cifs` (from `cifs-utils`) reports the
  actual failure reason (auth, unreachable host, wrong protocol version)
  more clearly than the plugin log can.
- The configured folder is relative to the share's root, not an absolute
  filesystem path - if the share itself already points at `\\host\Music`,
  leave Folder blank rather than typing `Music` again.
- Only `.mp3`, `.flac`, `.m4a`, `.aac`, `.ogg`, and `.wav` files are picked
  up, searched recursively through subfolders.

## Source Rotation/Fallback isn't switching sources

- Rotation needs a valid trial/license - check the log for a
  "Rotation blocked: ..." line, same premium gate as Pandora/Spotify.
  Fallback doesn't need one; it's free and always active once enabled.
- Rotation only switches when a schedule entry actually matches the
  current day/time - if nothing matches, the Source picked at the top of
  the page plays instead, which is expected, not a bug.
- The watchdog (`[playback-scheduler]` lines in the log) only polls every
  30 seconds - a swap won't be instant.
- Fallback only advances when the *current* source's playback has
  actually died (a dead process, or for Spotify a Web API check that it's
  no longer the active/playing device) - a source that's merely quiet
  between tracks isn't "dead."

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
(`encoreradio-pulse.service` / `announcementassistant-pulse.service`).
Encore Radio's installer checks for `/run/pulse/native` first and reuses
it if AA (or a previous Encore Radio install) already created it, rather
than standing up a second one. **Announcement Assistant's installer does
not currently do the same check** - if it's installed after Encore Radio,
it overwrites `/etc/pulse/system.pa` with its own (functionally
equivalent) copy and creates its own unit anyway, so both units end up
enabled. In practice this doesn't break playback (the configs are
interchangeable), but it does mean two systemd units are both trying to
own the same socket.

Encore Radio's uninstaller only reverts its PulseAudio changes when
`encoreradio-pulse.service` exists - i.e. only when Encore Radio was the
one that actually created the shared setup - so uninstalling Encore Radio
is safe even if AA is relying on it. The reverse isn't currently
guaranteed: uninstalling AA removes its own unit and restores its own
backup unconditionally, which can take the shared socket down (and, if
AA installed after Encore Radio, restore the wrong `system.pa`) even
if Encore Radio still needs it. If Spotify/Pandora/TuneIn playback stops
working after uninstalling AA, reinstalling Encore Radio recreates the
shared PulseAudio service.

## Spotify: "device not found" / "has it been paired yet?"

This means the Raspotify Connect device isn't currently visible to the
Spotify Web API. Open Spotify on your phone (same network as the FPP box)
and select the device name shown on the Encore Radio page from the
Connect/devices list. Also confirm `raspotify.service` is actually running
(`systemctl status raspotify.service`).

## Pandora/Spotify: playback works but stops after the trial

Expected - Pandora and Spotify are both premium, gated behind a shared
10-cumulative-hour trial (or a valid license key). Register on the Encore
Radio page and enter a license key once you have one. The custom stream
and TuneIn sources are unaffected; they're never gated.

## Relay port already in use / stale process

`scripts/er_relay.sh` tracks its own PID and hardens against leaving an
orphaned `ffmpeg` process on a failed start, but if something outside the
plugin's own lifecycle killed a process uncleanly, check
`ps aux | grep ffmpeg` and `cat /home/fpp/media/plugins/fpp-EncoreRadio/state/relay.pid`
- if they don't match, kill the stray process manually and run
"Encore Radio - Stop" once to clear plugin state.
