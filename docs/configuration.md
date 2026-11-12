# Configuration Reference

All settings live in `/home/fpp/media/plugindata/fpp-EncoreRadio/encoreradio.json`,
edited through the Encore Radio plugin page (not by hand, though it's
plain JSON if you ever need to inspect it). Trial-hour tracking lives
separately, in `trial_state.json` in the same directory - see the
`license.trialSecondsUsed` row below.

| Key | Description |
|---|---|
| `source` | `customstream`, `netshare`, `tunein`, `pandora`, `siriusxm`, or `spotify` |
| `volume` | 0-100, applied to whichever source is playing |
| `audioNormalize` | Off by default. Evens out loudness differences between stations/streams (ffmpeg `dynaudnorm`), at some CPU cost. Takes effect on the next Start or station switch, not live. |
| `relay.port` | Local port the custom-stream/network-share/TuneIn/Pandora relay listens on (default 8123) |
| `customstream.name` / `streamUrl` | A directly-typed internet radio stream URL and label - this is the *active* one, what actually plays when `source` is `customstream` |
| `customstream.saved` | Free - array of `{name, streamUrl}` presets the operator can save and reload into `customstream.name`/`streamUrl` from the page. Also doubles as the automatic Internet Radio failover chain: whenever `source` is `customstream` and 2+ distinct stations are configured (active + saved), a background watchdog advances to the next one in the list (wrapping around) if the current stream dies, updating `customstream.name`/`streamUrl` to match. Not gated by license/premium. |
| `netshare.sharePath` | SMB/CIFS share, e.g. `//192.168.1.50/Music` |
| `netshare.username` / `password` | Leave username blank for guest access |
| `netshare.folder` | Subfolder within the share to play (blank = share root, searched recursively) |
| `rotation.enabled` | Premium - play a different source on a day/time schedule instead of always `source` |
| `rotation.entries` | Array of `{days: [...], startTime, endTime, source}` - `days` are lowercase 3-letter (`mon`..`sun`); `endTime <= startTime` wraps past midnight |
| `fallback.enabled` | Free - auto-recover to the next source if the current one fails to start or dies mid-play |
| `fallback.chain` | Ordered array of source names to try in sequence, e.g. `["spotify", "pandora", "tunein", "netshare"]` |
| `tunein.stationId` / `stationName` / `streamUrl` | Set by the station search picker |
| `pandora.username` / `password` / `stationId` / `stationName` | Pandora account + chosen station |
| `siriusxm.username` / `password` | **Premium, Alpha.** Your SiriusXM subscriber login. Stored plaintext (mode 600), passed to the bundled [aiosxm](https://github.com/MizterB/aiosxm) proxy via the environment, never on a command line. |
| `siriusxm.channel` | A SiriusXM channel **number** (as in the SiriusXM app) or a channel name - resolved to the live channel at Start time |
| `siriusxm.channelName` | Friendly label only (header/status); defaults to `channel` |
| `siriusxm.proxyPort` | Loopback port the aiosxm proxy listens on (default 8124; must differ from `relay.port`) |
| `siriusxm.bitrate` | Upstream pull quality: `32k`/`64k`/`96k`/`128k`/`256k` (default `128k` - the relay re-encodes to 128k MP3 anyway) |
| `spotify.clientId` / `clientSecret` | Your own Spotify Developer App credentials |
| `spotify.accessToken` / `refreshToken` / `tokenExpiresAt` | Set by the OAuth flow - don't edit directly |
| `spotify.playlistUri` / `playlistName` | Set by the playlist search picker |
| `spotify.deviceName` | The Raspotify Connect device name, set at install time |
| `announce.enabled` | Whether to fire an Announcement Assistant slot on a schedule |
| `announce.slot` | Which AA slot (0-5) |
| `announce.mode` | `cadence` (every N minutes) or `times` (specific HH:MM times) |
| `announce.cadenceMinutes` / `times` | The schedule itself |
| `license.email` / `key` | Set via the License section |
| `trial_state.json`: `trialSecondsUsed` | Separate file, same directory - cumulative Pandora, SiriusXM **and** Spotify playback time counted against the 10-hour trial (the free sources never count), only ever written by `er_track_usage.sh` |
| `ui.onboardingSeen` / `onboardingTourEnabled` | First-run guided tour state |

## FPP Commands

Add these to FPP's own Scheduler (Content Setup > Scheduler):

- **Encore Radio - Start** - begins playback of the configured source.
- **Encore Radio - Stop** - stops playback (pauses Spotify via the Web API,
  kills the relay/ffplay for the custom stream/TuneIn/Pandora).
- **Encore Radio - Play Station** - plays one named Internet Radio station,
  picked from a *Station* dropdown listing your Saved Stations. Free. If
  something is already playing it switches over, so you can schedule one
  station for the day and another for the night:

  | Scheduler entry | Command |
  |---|---|
  | 07:00 | Encore Radio - Play Station, Station = `Day Mix` |
  | before the show | Encore Radio - Stop |
  | after the show | Encore Radio - Play Station, Station = `Night Chill` |

  The picked station becomes the active `customstream` (the same thing
  clicking it on the page and saving does), so a later plain **Start**
  keeps playing it, and failover to the other Saved Stations still
  applies. It overrides the configured `source` and Rotation's pick at the
  moment it runs, but if Rotation is enabled and its watchdog is already
  running from an earlier Start, the next Rotation check can still swap
  away - don't combine the two for the same time window. An unknown
  station name is logged and leaves current playback alone.

## Spotify setup (premium)

1. Create a free app at [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard).
2. Add this exact Redirect URI to it: `https://encoreradio-license.nscilingo.workers.dev/spotify/callback`.
   Spotify requires HTTPS (or an exact `127.0.0.1` loopback) and rejects a
   plain LAN address like `http://192.168.x.x`, so every Encore Radio
   install points at this one fixed HTTPS URL, which bounces the browser
   straight back to that specific device's own local callback page - see
   `docs/how-it-works.md`.
3. Enter the Client ID/Secret on the Encore Radio page and click
   "Save & Connect to Spotify" - this authorizes Encore Radio's own API
   calls (search, start/stop playback).
4. Separately, pair the Raspotify Connect device once: open Spotify on
   your phone (same network as the FPP box), tap the Connect/devices
   icon, and select the device name shown on the Encore Radio page. This
   is what authenticates Raspotify itself - step 3 doesn't cover it.
5. Search for and pick a playlist.

Both setup steps are one-time only.

## SiriusXM setup (premium - Alpha)

> **Alpha / use at your own risk.** SiriusXM playback uses the unofficial,
> open-source [aiosxm](https://github.com/MizterB/aiosxm) project, which talks
> to SiriusXM's private web API. SiriusXM can change or break it at any time,
> and using it may be against SiriusXM's terms of service. It is for **personal
> use** with **your own active SiriusXM subscription** only. Unlike Pandora or
> Spotify there is no second device involved - the stream is logged in and
> relayed entirely on the FPP box.

**Requirements:** **Python 3.12 or newer** - current FPP 10.x (Debian 13
Trixie) ships Python 3.13, so it works out of the box on both 64-bit and
32-bit ARM (aiosxm is pure Python and aiohttp publishes armv7 wheels). Older
systems with Python 3.11 or earlier (e.g. FPP 9.x) are not supported yet; the
Encore Radio page shows a notice when the backend is unavailable on your box.

1. On the Encore Radio page, pick **SiriusXM** as the source.
2. Enter your SiriusXM **username/email** and **password**.
3. Enter the **channel** - either its number (as shown in the SiriusXM app,
   e.g. `2`) or its name (e.g. `SiriusXM Hits 1`). It's matched against the
   live channel list the first time you Start; if it can't be matched, the
   available channel names are written to the Encore Radio log.
4. Save. Then Start (or schedule a Start) as with any other source.

How it works: the plugin installs aiosxm into its own Python virtual
environment and, on Start, runs it as a loopback proxy that re-serves your
chosen channel as a standard AES-128 HLS stream; the normal relay reads and
re-streams that exactly like any other station. A live channel picker (instead
of typing the number/name) is planned for a later release.
