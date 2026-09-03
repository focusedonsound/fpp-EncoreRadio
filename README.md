# 📻 Encore Radio — After-Hours Streaming for Falcon Player

Keep your show's "radio station" feel going after the lights go dark.
Encore Radio streams TuneIn stations and Pandora (free) or a custom Spotify
playlist (premium) during your after-hours window, and can trigger
[Announcement Assistant](https://github.com/focusedonsound/fpp-AnnouncementAssistant)
on a schedule for radio-station-style announcements ("Thanks for tuning in!").

## Status

This is an early, in-progress build. Milestone 1 (this checkout) covers the
free-tier core: TuneIn + Pandora playback, single source, FPP 9.x/10.x
compatible audio path, and the Start/Stop FPP Commands needed to drive it
from FPP's own scheduler. Announcement Assistant integration, Spotify
(premium), licensing/trial gating, and the guided first-run tour land in
later milestones — see `docs/` (added as those land) for details.

## How it works

- Pick a source (TuneIn station or Pandora station) in the plugin's page.
- Add two FPP Schedule entries: one calling **Encore Radio - Start** for
  when your show ends, one calling **Encore Radio - Stop** for when you want
  streaming to end (e.g. overnight).
- Each backend (TuneIn's direct stream, or Pianobar for Pandora) feeds a
  small local relay. Playback then goes through whichever path your FPP
  version supports: FPP 10.x's native `Play Media` Stream Slot command, or
  FPP 9.x's PulseAudio sink (the same audio path
  [Announcement Assistant](https://github.com/focusedonsound/fpp-AnnouncementAssistant)
  already knows how to duck).

## Requirements

- Falcon Player (FPP) 9.x or 10.x
- `ffmpeg`, `pianobar`, `curl`, `python3`, `jq` (installed automatically)

## License

Free for personal, hobbyist, and noncommercial use under the
[PolyForm Noncommercial License 1.0.0](LICENSE). Using this in a commercial
or paid-event display? Contact license.request@christmasinboontontwp.com for
a commercial license, same as Announcement Assistant.
