# Configuration Reference

All settings live in `/home/fpp/media/config/encoreradio.json`, edited
through the Encore Radio plugin page (not by hand, though it's plain JSON
if you ever need to inspect it).

| Key | Description |
|---|---|
| `source` | `customstream`, `tunein`, `pandora`, or `spotify` |
| `volume` | 0-100, applied to whichever source is playing |
| `relay.port` | Local port the custom-stream/TuneIn/Pandora relay listens on (default 8123) |
| `customstream.name` / `streamUrl` | A directly-typed internet radio stream URL and label |
| `tunein.stationId` / `stationName` / `streamUrl` | Set by the station search picker |
| `pandora.username` / `password` / `stationId` / `stationName` | Pandora account + chosen station |
| `spotify.clientId` / `clientSecret` | Your own Spotify Developer App credentials |
| `spotify.accessToken` / `refreshToken` / `tokenExpiresAt` | Set by the OAuth flow - don't edit directly |
| `spotify.playlistUri` / `playlistName` | Set by the playlist search picker |
| `spotify.deviceName` | The Raspotify Connect device name, set at install time |
| `announce.enabled` | Whether to fire an Announcement Assistant slot on a schedule |
| `announce.slot` | Which AA slot (0-5) |
| `announce.mode` | `cadence` (every N minutes) or `times` (specific HH:MM times) |
| `announce.cadenceMinutes` / `times` | The schedule itself |
| `license.email` / `key` | Set via the License section |
| `license.trialSecondsUsed` | Cumulative Spotify playback time - only ever written by `er_track_usage.sh` |
| `ui.onboardingSeen` / `onboardingTourEnabled` | First-run guided tour state |

## FPP Commands

Add these to FPP's own Scheduler (Content Setup > Scheduler):

- **Encore Radio - Start** - begins playback of the configured source.
- **Encore Radio - Stop** - stops playback (pauses Spotify via the Web API,
  kills the relay/ffplay for the custom stream/TuneIn/Pandora).

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
