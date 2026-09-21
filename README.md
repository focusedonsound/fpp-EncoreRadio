# 📻 Encore Radio

**Keep the show's radio station feel going after the lights go dark.**

Your synchronized light show ends for the night — but does the magic
have to stop? Encore Radio turns your Falcon Player controller into a
real after-hours radio station: streaming music, scheduled announcements,
and a smooth handoff from "the show" to "still the show, just quieter."
Set it up once, and it runs itself every night on your own FPP schedule.

## Why people install this

- **It just works, unattended.** Add two FPP Schedule entries — Start,
  Stop — and Encore Radio handles the rest, every single night, no phone
  or app required.
- **Bring your own music library.** Point it at a folder on your NAS or
  any network share and it plays your entire collection, shuffled — no
  copying files onto the controller, no size limits.
- **A real internet radio station**, TuneIn included, free.
- **Source Fallback, free too** — if one source has a bad night, Encore
  Radio quietly recovers to the next one in line. The music doesn't stop.
- **Go premium for Pandora and Spotify** — your own curated stations and
  playlists, not just a fixed stream.
- **Source Rotation (premium)** — a different station or playlist
  depending on the night or the hour. Upbeat for the early crowd, mellow
  after the kids are in bed, something different on weekends.
- **Radio-station-style announcements**, layered in automatically if you
  run [Announcement Assistant](https://github.com/focusedonsound/fpp-AnnouncementAssistant) —
  "Thanks for tuning in!" without lifting a finger.

## Free vs. Premium

| | Free | Premium |
|---|---|---|
| Custom internet radio stream | ✅ | ✅ |
| Network share (your own music library) | ✅ | ✅ |
| TuneIn | ✅ | ✅ |
| Pandora | | ✅ |
| Spotify | | ✅ |
| Source Fallback (auto-recovery) | ✅ | ✅ |
| Source Rotation (day/time schedule) | | ✅ |
| Announcement Assistant integration | ✅ | ✅ |

Try any premium feature free for 10 hours of real playback. After that,
a license key unlocks it for the year.

## Getting started

1. Install Encore Radio from the FPP Plugin Manager (or add this repo
   manually).
2. Open the Encore Radio page and pick a source - Pandora, Spotify, and
   Source Rotation need a quick, free email registration (or a license
   key, if you already have one) first; everything else is unlocked
   right away.
3. Add two FPP Schedule entries: **Encore Radio - Start** for when your
   show ends, **Encore Radio - Stop** for when you want it to end for the
   night.

That's it. For Spotify setup, network share details, and the full
settings reference, see [`docs/configuration.md`](docs/configuration.md).
Running into something odd? Check [`docs/troubleshooting.md`](docs/troubleshooting.md)
first.

## Requirements

- Falcon Player (FPP) 9.x or 10.x
- A Spotify Premium account, if you want the Spotify source

## License

Free for personal, hobbyist, and noncommercial use under the
[PolyForm Noncommercial License 1.0.0](LICENSE). Using this in a
commercial or paid-event display? Contact
license.request@christmasinboontontwp.com for a commercial license.

---

Questions, ideas, or something not working right? [Open an issue](https://github.com/focusedonsound/fpp-EncoreRadio/issues) -
happy to help.
