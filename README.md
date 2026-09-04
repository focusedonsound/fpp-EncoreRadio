# 📻 Encore Radio — After-Hours Streaming for Falcon Player

Keep your show's "radio station" feel going after the lights go dark.
Encore Radio streams a custom internet radio URL, a folder of your own
music from a network share, or TuneIn stations (free), or Pandora and a
custom Spotify playlist (premium), during your after-hours window, and
can trigger
[Announcement Assistant](https://github.com/focusedonsound/fpp-AnnouncementAssistant)
on a schedule for radio-station-style announcements ("Thanks for tuning in!").

## Status

Feature-complete: free custom-stream/network-share/TuneIn playback,
premium Pandora/Spotify (Spotify via Raspotify + your own Spotify
Developer App), premium Source Rotation (a different source on a
day/time schedule) and Source Fallback (auto-recovery if a source fails
to start or dies mid-play), Announcement Assistant integration,
trial-hour/license gating against a small
[license server](https://github.com/focusedonsound/fpp-EncoreRadio-license-server),
and a first-run guided walkthrough on the plugin page. Verified on real
FPP 9.5 and 10.0 hardware end-to-end.

## How it works

- Pick a source (custom stream URL, TuneIn station, Pandora station, or a
  Spotify playlist) on the Encore Radio plugin page.
- Add two FPP Schedule entries: one calling **Encore Radio - Start** for
  when your show ends, one calling **Encore Radio - Stop** for when you
  want streaming to end (e.g. overnight).
- If [Announcement Assistant](https://github.com/focusedonsound/fpp-AnnouncementAssistant)
  is installed, optionally schedule one of its slots to play automatically
  during after-hours - no extra FPP schedule entries needed for that.

See `docs/how-it-works.md` for the audio architecture, `docs/configuration.md`
for the full settings reference (including Spotify setup), and
`docs/troubleshooting.md` for common issues.

## Requirements

- Falcon Player (FPP) 9.x or 10.x
- `ffmpeg`, `pianobar`, `curl`, `python3`, `jq` (installed automatically)
- Raspotify (installed automatically) if you want the Spotify (premium)
  source - requires a Spotify Premium account

## License

Free for personal, hobbyist, and noncommercial use under the
[PolyForm Noncommercial License 1.0.0](LICENSE). Using this in a commercial
or paid-event display? Contact license.request@christmasinboontontwp.com for
a commercial license, same as Announcement Assistant.
