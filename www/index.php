<?php
$configFile = "/home/fpp/media/config/encoreradio.json";

function loadConfig($path) {
  $cfg = [
    "source" => "",
    "relay" => ["port" => 8123],
    "volume" => 70,
    "customstream" => ["name" => "", "streamUrl" => ""],
    "netshare" => ["sharePath" => "", "username" => "", "password" => "", "folder" => ""],
    "tunein" => ["stationId" => "", "stationName" => "", "streamUrl" => ""],
    "pandora" => ["username" => "", "password" => "", "stationId" => "", "stationName" => ""],
    "spotify" => ["clientId" => "", "clientSecret" => "", "accessToken" => "", "refreshToken" => "", "tokenExpiresAt" => 0, "playlistUri" => "", "playlistName" => "", "deviceName" => ""],
    "announce" => ["enabled" => false, "slot" => "", "mode" => "cadence", "cadenceMinutes" => 15, "times" => []],
    "license" => ["email" => "", "registered" => false, "key" => "", "trialSecondsUsed" => 0],
    "ui" => ["onboardingSeen" => false, "onboardingTourEnabled" => true],
  ];
  if (file_exists($path)) {
    $j = json_decode(@file_get_contents($path), true);
    if (is_array($j)) $cfg = array_replace_recursive($cfg, $j);
  }
  return $cfg;
}

function loadAASlots() {
  $path = "/home/fpp/media/config/announcementassistant.json";
  $slots = [];
  if (file_exists($path)) {
    $j = json_decode(@file_get_contents($path), true);
    if (is_array($j) && isset($j["buttons"]) && is_array($j["buttons"])) {
      foreach ($j["buttons"] as $i => $btn) {
        $label = trim((string)($btn["label"] ?? ("Slot " . ($i + 1))));
        $slots[] = ["index" => $i, "label" => $label];
      }
    }
  }
  return $slots;
}

$cfg = loadConfig($configFile);
$aaSlots = loadAASlots();
$aaInstalled = file_exists("/home/fpp/media/config/announcementassistant.json");
$spotifyConnected = trim((string)$cfg["spotify"]["refreshToken"]) !== "";
$raspotifyInstalled = file_exists("/usr/bin/librespot");

$registered = (bool)($cfg["license"]["registered"] ?? false);
$hasLicenseKey = trim((string)$cfg["license"]["key"]) !== "";
$trialSecondsUsed = (int)($cfg["license"]["trialSecondsUsed"] ?? 0);
$trialSecondsRemaining = max(0, (10 * 3600) - $trialSecondsUsed);
$trialHoursRemaining = round($trialSecondsRemaining / 3600, 1);
?>

<style>
/* Encore Radio - explicit colours for FPP 9.x / 10.x compatibility
   (same reasoning as Announcement Assistant / HDMI CEC+: FPP 9.x's
   Bootstrap 4 dark theme renders btn-outline-light as white-on-white,
   so buttons here are hardcoded to look the same on every FPP version). */
.er-btn {
  display: inline-flex;
  align-items: center;
  gap: .3rem;
  padding: .35rem .8rem;
  font-size: .875rem;
  font-weight: 500;
  line-height: 1.5;
  text-align: center;
  white-space: nowrap;
  cursor: pointer;
  border: 1px solid #3a7fc1;
  border-radius: .3rem;
  text-decoration: none !important;
  background-color: #1a6eb5;
  color: #fff !important;
  transition: background-color .15s ease-in-out, border-color .15s;
  vertical-align: middle;
}
.er-btn:hover, .er-btn:focus {
  background-color: #155a94;
  border-color: #0e4370;
  color: #fff !important;
  text-decoration: none !important;
}
.er-btn-secondary {
  background-color: #6c757d;
  border-color: #6c757d;
}
.er-btn-secondary:hover, .er-btn-secondary:focus {
  background-color: #5c636a;
  border-color: #565e64;
}
.er-btn-success {
  background-color: #198754;
  border-color: #146c43;
}
.er-btn-success:hover, .er-btn-success:focus {
  background-color: #146c43;
  border-color: #0f5132;
}
.er-btn-danger {
  background-color: #b02a37;
  border-color: #842029;
}
.er-btn-danger:hover, .er-btn-danger:focus {
  background-color: #842029;
  border-color: #6a1a20;
}
.er-btn:disabled, .er-btn.disabled {
  opacity: .55;
  cursor: not-allowed;
  pointer-events: none;
}
.er-pill {
  display: inline-flex; align-items: center; gap: .3rem;
  padding: .25rem .65rem; border-radius: 999px; font-size: .8rem; font-weight: 600;
  color: #fff; white-space: nowrap;
}
@media (max-width: 640px) {
  .er-page-header { flex-wrap: wrap !important; row-gap: .5rem; }
  .er-page-header > *:first-child { flex: 1 1 100%; }
  .er-link-row { flex-wrap: wrap; width: 100%; }
}

#er-tour-highlight {
  position: fixed; z-index: 10050; pointer-events: none;
  border: 2px solid #1a6eb5; border-radius: 6px;
  box-shadow: 0 0 0 4000px rgba(0,0,0,0.45);
  transition: top 0.2s, left 0.2s, width 0.2s, height 0.2s;
}
#er-tour-popup {
  position: fixed; z-index: 10051; max-width: 340px; width: calc(100% - 24px);
  background-color: #fff; color: #212529; border: 1px solid #1a6eb5; border-radius: .4rem;
  box-shadow: 0 .5rem 1rem rgba(0,0,0,.35);
}
#er-tour-arrow {
  position: fixed; z-index: 10051; width: 0; height: 0;
  border-left: 9px solid transparent; border-right: 9px solid transparent;
}
.er-tour-arrow-below { border-top: 9px solid #fff; }
.er-tour-arrow-above { border-bottom: 9px solid #fff; }
</style>

<div class="d-flex justify-content-between align-items-center mb-2 er-page-header">
  <h2 class="mb-0"><i class="fas fa-fw fa-broadcast-tower"></i> Encore Radio</h2>
  <div class="d-flex align-items-center gap-2 er-link-row">
    <a href="https://github.com/focusedonsound/fpp-EncoreRadio"
       target="_blank" rel="noopener noreferrer"
       class="er-btn">
      <i class="fas fa-fw fa-code-branch"></i> GitHub Repo
    </a>
    <a href="https://github.com/focusedonsound/fpp-EncoreRadio/issues"
       target="_blank" rel="noopener noreferrer"
       class="er-btn er-btn-secondary">
      <i class="fas fa-fw fa-bug"></i> Report an Issue
    </a>
  </div>
</div>
<p class="text-muted">
  Keep the show's radio station feel going after the lights go dark.
  A <strong>custom internet radio URL</strong>, a <strong>network
  share</strong> of your own music, and <strong>TuneIn</strong> are all
  free; <strong>Pandora</strong> and <strong>Spotify</strong> are
  premium features. Add FPP Schedule
  entries calling <strong>Encore Radio - Start</strong> /
  <strong>Encore Radio - Stop</strong> for your after-hours window, and
  you're set.
</p>

<p>
  <a href="#" id="er-onboarding-replay" class="small me-2"><i class="fas fa-fw fa-circle-play"></i> Replay walkthrough</a>
  <label class="small text-muted">
    <input type="checkbox" name="ui_onboardingTourEnabled" id="er-onboardingTourEnabled" form="erForm"
           <?php echo $cfg["ui"]["onboardingTourEnabled"] ? "checked" : ""; ?> />
    Show this walkthrough for new visits to this page
  </label>
</p>

<div class="fppTableWrapper fppTableWrapperAsTable mb-3" id="er-fieldset-signup">
  <div class="fppTableContents">
    <table class="fppSelectableRowTable" style="width:100%;">
      <thead>
        <tr><th style="padding:8px;"><i class="fas fa-fw fa-envelope"></i> Get Started</th></tr>
      </thead>
      <tbody>
        <tr><td style="padding:8px;">
          <?php if ($registered): ?>
            <p class="mb-0"><i class="fas fa-fw fa-circle-check" style="color:#198754;"></i> Registered as <strong><?php echo htmlspecialchars($cfg["license"]["email"]); ?></strong>. Everything below is unlocked.</p>
          <?php else: ?>
            <p class="text-muted">
              Just an email address - nothing else required to start using
              Encore Radio (TuneIn included). We'll only use it to let you
              know if your Pandora/Spotify trial is running low, or when
              it runs out.
            </p>
            <div class="d-flex gap-2 align-items-center flex-wrap">
              <input type="email" class="form-control form-control-sm" id="er-signup-email" placeholder="you@example.com" style="width:100%; max-width:320px;" />
              <button type="button" class="er-btn" onclick="erSignUp()"><i class="fas fa-fw fa-user-plus"></i> Get Started</button>
            </div>
            <span id="er-signup-status" class="d-block mt-2 small"></span>
          <?php endif; ?>
        </td></tr>
      </tbody>
    </table>
  </div>
</div>

<form id="erForm" onsubmit="return false;">
<fieldset id="er-gate" <?php echo $registered ? "" : "disabled"; ?> style="<?php echo $registered ? "" : "opacity:0.55;"; ?>">

  <div class="fppTableWrapper fppTableWrapperAsTable mb-3" id="er-fieldset-source">
    <div class="fppTableContents">
      <table class="fppSelectableRowTable" style="width:100%;">
        <thead>
          <tr><th colspan="2" style="padding:8px;"><i class="fas fa-fw fa-satellite-dish"></i> Source</th></tr>
        </thead>
        <tbody>
          <tr>
            <td colspan="2" style="padding:8px;">
              <div class="d-flex gap-3 flex-wrap">
                <div class="form-check">
                  <input class="form-check-input" type="radio" name="source" id="er-source-customstream" value="customstream" <?php echo $cfg["source"] === "customstream" ? "checked" : ""; ?> />
                  <label class="form-check-label" for="er-source-customstream"><strong>Internet Radio (URL)</strong> <span class="text-muted small">- free</span></label>
                </div>
                <div class="form-check">
                  <input class="form-check-input" type="radio" name="source" id="er-source-netshare" value="netshare" <?php echo $cfg["source"] === "netshare" ? "checked" : ""; ?> />
                  <label class="form-check-label" for="er-source-netshare"><strong>Network Share</strong> <span class="text-muted small">- free</span></label>
                </div>
                <div class="form-check">
                  <input class="form-check-input" type="radio" name="source" id="er-source-tunein" value="tunein" <?php echo $cfg["source"] === "tunein" ? "checked" : ""; ?> />
                  <label class="form-check-label" for="er-source-tunein"><strong>TuneIn</strong> <span class="text-muted small">- free</span></label>
                </div>
                <div class="form-check">
                  <input class="form-check-input" type="radio" name="source" id="er-source-pandora" value="pandora" <?php echo $cfg["source"] === "pandora" ? "checked" : ""; ?> />
                  <label class="form-check-label" for="er-source-pandora"><strong>Pandora</strong> <span class="text-muted small">- premium</span></label>
                </div>
                <div class="form-check">
                  <input class="form-check-input" type="radio" name="source" id="er-source-spotify" value="spotify" <?php echo $cfg["source"] === "spotify" ? "checked" : ""; ?> />
                  <label class="form-check-label" for="er-source-spotify"><strong>Spotify</strong> <span class="text-muted small">- premium</span></label>
                </div>
              </div>
            </td>
          </tr>

          <tr id="er-customstream-section" style="display:none;">
            <td colspan="2" style="padding:8px;">
              <table style="width:100%; max-width:520px;">
                <tr>
                  <td class="py-1">Station Name (label only)</td>
                  <td class="py-1"><input type="text" class="form-control form-control-sm" name="customstream_name" value="<?php echo htmlspecialchars($cfg["customstream"]["name"]); ?>" /></td>
                </tr>
                <tr>
                  <td class="py-1">Stream URL</td>
                  <td class="py-1"><input type="text" class="form-control form-control-sm" name="customstream_streamUrl" placeholder="http://example.com/stream.mp3" value="<?php echo htmlspecialchars($cfg["customstream"]["streamUrl"]); ?>" /></td>
                </tr>
              </table>
              <p class="small text-muted mt-2 mb-0">
                <i class="fas fa-fw fa-circle-info"></i>
                Any plain HTTP/HTTPS internet radio stream URL - handy for a
                station that isn't in TuneIn's directory. No login required.
              </p>
            </td>
          </tr>

          <tr id="er-netshare-section" style="display:none;">
            <td colspan="2" style="padding:8px;">
              <table style="width:100%; max-width:520px;">
                <tr>
                  <td class="py-1">Share Path</td>
                  <td class="py-1"><input type="text" class="form-control form-control-sm" name="netshare_sharePath" placeholder="//192.168.1.50/Music" value="<?php echo htmlspecialchars($cfg["netshare"]["sharePath"]); ?>" /></td>
                </tr>
                <tr>
                  <td class="py-1">Username</td>
                  <td class="py-1"><input type="text" class="form-control form-control-sm" name="netshare_username" placeholder="(leave blank for guest access)" value="<?php echo htmlspecialchars($cfg["netshare"]["username"]); ?>" /></td>
                </tr>
                <tr>
                  <td class="py-1">Password</td>
                  <td class="py-1">
                    <div class="d-flex gap-2 align-items-center">
                      <input type="password" class="form-control form-control-sm" name="netshare_password" id="er-netshare-password"
                             value="<?php echo $cfg["netshare"]["password"] !== "" ? "__unchanged__" : ""; ?>" />
                      <button type="button" class="er-btn er-btn-secondary" onclick="erToggleNetsharePassword()"><i class="fas fa-fw fa-eye"></i> Show</button>
                    </div>
                  </td>
                </tr>
                <tr>
                  <td class="py-1">Folder</td>
                  <td class="py-1"><input type="text" class="form-control form-control-sm" name="netshare_folder" placeholder="Christmas (leave blank for the share's root)" value="<?php echo htmlspecialchars($cfg["netshare"]["folder"]); ?>" /></td>
                </tr>
              </table>
              <p class="small text-muted mt-2 mb-0">
                <i class="fas fa-fw fa-circle-info"></i>
                Any existing SMB/CIFS share - a NAS, or a shared folder from
                a PC on the same network. Plays every audio file found in
                the chosen folder (and its subfolders), shuffled, on a
                loop - nothing needs to be copied onto this device.
              </p>
            </td>
          </tr>

          <tr id="er-tunein-section" style="display:none;">
            <td colspan="2" style="padding:8px;">
              <div class="d-flex gap-2 flex-wrap align-items-center">
                <input type="text" id="er-tunein-search" class="form-control form-control-sm" placeholder="Search TuneIn stations..." style="width:100%; max-width:320px;" />
                <button type="button" class="er-btn" onclick="erSearchTuneIn()"><i class="fas fa-fw fa-magnifying-glass"></i> Search</button>
              </div>
              <div id="er-tunein-results" class="mt-2"></div>
              <div class="mt-2">
                Selected station: <strong id="er-tunein-selected-name"><?php echo htmlspecialchars($cfg["tunein"]["stationName"]); ?></strong>
              </div>
              <input type="hidden" name="tunein_stationId" id="er-tunein-stationId" value="<?php echo htmlspecialchars($cfg["tunein"]["stationId"]); ?>" />
              <input type="hidden" name="tunein_stationName" id="er-tunein-stationName" value="<?php echo htmlspecialchars($cfg["tunein"]["stationName"]); ?>" />
              <input type="hidden" name="tunein_streamUrl" id="er-tunein-streamUrl" value="<?php echo htmlspecialchars($cfg["tunein"]["streamUrl"]); ?>" />
            </td>
          </tr>

          <tr id="er-pandora-section" style="display:none;">
            <td colspan="2" style="padding:8px;">
              <table style="width:100%; max-width:520px;">
                <tr>
                  <td class="py-1">Pandora Username</td>
                  <td class="py-1"><input type="text" class="form-control form-control-sm" name="pandora_username" value="<?php echo htmlspecialchars($cfg["pandora"]["username"]); ?>" /></td>
                </tr>
                <tr>
                  <td class="py-1">Pandora Password</td>
                  <td class="py-1">
                    <div class="d-flex gap-2 align-items-center">
                      <input type="password" class="form-control form-control-sm" name="pandora_password" id="er-pandora-password"
                             value="<?php echo $cfg["pandora"]["password"] !== "" ? "__unchanged__" : ""; ?>" />
                      <button type="button" class="er-btn er-btn-secondary" onclick="erTogglePassword()"><i class="fas fa-fw fa-eye"></i> Show</button>
                    </div>
                  </td>
                </tr>
                <tr>
                  <td class="py-1">Station ID</td>
                  <td class="py-1"><input type="text" class="form-control form-control-sm" name="pandora_stationId" value="<?php echo htmlspecialchars($cfg["pandora"]["stationId"]); ?>" /></td>
                </tr>
                <tr>
                  <td class="py-1">Station Name (label only)</td>
                  <td class="py-1"><input type="text" class="form-control form-control-sm" name="pandora_stationName" value="<?php echo htmlspecialchars($cfg["pandora"]["stationName"]); ?>" /></td>
                </tr>
              </table>
              <p class="small text-muted mt-2 mb-0">
                <i class="fas fa-fw fa-circle-info"></i>
                Station ID is the number from your Pandora station's URL. Pianobar
                prints available station IDs to the Encore Radio log on first login
                if you're not sure which to use.
              </p>
            </td>
          </tr>

          <tr id="er-spotify-section" style="display:none;">
            <td colspan="2" style="padding:8px;">
              <?php if (!$raspotifyInstalled): ?>
                <p class="text-danger">
                  <i class="fas fa-fw fa-triangle-exclamation"></i>
                  Raspotify (the Spotify Connect client this plugin uses) wasn't
                  installed successfully - check the install log. Your device's
                  processor architecture may not be supported.
                </p>
              <?php endif; ?>

              <p class="small text-muted">
                Spotify needs two separate one-time setup steps:
                <strong>1)</strong> connect your own Spotify Developer App below (so
                Encore Radio can search your playlists and start playback), and
                <strong>2)</strong> pair this device once via your phone's Spotify
                app on the same network (open Spotify, tap the device/Connect icon,
                and select
                "<code><?php echo htmlspecialchars($cfg["spotify"]["deviceName"] ?: '(set after install)'); ?></code>").
                Neither step is needed again after that.
              </p>

              <table style="width:100%; max-width:600px;">
                <tr>
                  <td class="py-1">Spotify Client ID</td>
                  <td class="py-1"><input type="text" class="form-control form-control-sm" name="spotify_clientId" value="<?php echo htmlspecialchars($cfg["spotify"]["clientId"]); ?>" /></td>
                </tr>
                <tr>
                  <td class="py-1">Spotify Client Secret</td>
                  <td class="py-1">
                    <div class="d-flex gap-2 align-items-center">
                      <input type="password" class="form-control form-control-sm" name="spotify_clientSecret" id="er-spotify-secret"
                             value="<?php echo $cfg["spotify"]["clientSecret"] !== "" ? "__unchanged__" : ""; ?>" />
                      <button type="button" class="er-btn er-btn-secondary" onclick="erToggleSpotifySecret()"><i class="fas fa-fw fa-eye"></i> Show</button>
                    </div>
                  </td>
                </tr>
              </table>
              <p class="small text-muted">
                Create a free app at
                <a href="https://developer.spotify.com/dashboard" target="_blank">developer.spotify.com/dashboard</a>,
                then add this exact Redirect URI to it (the same fixed URL
                for every Encore Radio install - Spotify requires HTTPS,
                which this box's own local address can't provide):
                <code>https://encoreradio-license.nscilingo.workers.dev/spotify/callback</code>
              </p>

              <div class="d-flex align-items-center gap-2 mt-2 mb-2 flex-wrap">
                <button type="button" class="er-btn" onclick="erSave().then(erConnectSpotify)">
                  <i class="fas fa-fw fa-link"></i> Save &amp; Connect to Spotify
                </button>
                <span class="er-pill" style="background-color:<?php echo $spotifyConnected ? '#198754' : '#6c757d'; ?>;">
                  <i class="fas fa-fw fa-circle fa-2xs"></i>
                  <?php echo $spotifyConnected ? "Connected" : "Not connected yet"; ?>
                </span>
              </div>

              <?php if ($spotifyConnected): ?>
                <div class="d-flex gap-2 flex-wrap align-items-center">
                  <input type="text" id="er-spotify-search" class="form-control form-control-sm" placeholder="Search playlists (yours or public)..." style="width:100%; max-width:320px;" />
                  <button type="button" class="er-btn" onclick="erSearchSpotify()"><i class="fas fa-fw fa-magnifying-glass"></i> Search</button>
                </div>
                <div class="d-flex gap-2 flex-wrap align-items-center mt-2">
                  <input type="text" id="er-spotify-link" class="form-control form-control-sm" placeholder="...or paste a playlist link (open.spotify.com/playlist/...)" style="width:100%; max-width:400px;" />
                  <button type="button" class="er-btn er-btn-secondary" onclick="erUseSpotifyLink()"><i class="fas fa-fw fa-link"></i> Use Link</button>
                </div>
                <div id="er-spotify-results" class="mt-2"></div>
                <div class="mt-2">
                  Selected playlist: <strong id="er-spotify-selected-name"><?php echo htmlspecialchars($cfg["spotify"]["playlistName"]); ?></strong>
                </div>
              <?php endif; ?>
              <input type="hidden" name="spotify_playlistUri" id="er-spotify-playlistUri" value="<?php echo htmlspecialchars($cfg["spotify"]["playlistUri"]); ?>" />
              <input type="hidden" name="spotify_playlistName" id="er-spotify-playlistName" value="<?php echo htmlspecialchars($cfg["spotify"]["playlistName"]); ?>" />
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>

  <div class="fppTableWrapper fppTableWrapperAsTable mb-3" id="er-fieldset-volume">
    <div class="fppTableContents">
      <table class="fppSelectableRowTable" style="width:100%;">
        <thead>
          <tr><th style="padding:8px;"><i class="fas fa-fw fa-volume-high"></i> Volume</th></tr>
        </thead>
        <tbody>
          <tr>
            <td style="padding:8px;">
              <input type="range" class="form-range" style="max-width:400px;" name="volume" id="er-volume" min="0" max="100" step="1"
                     value="<?php echo (int)$cfg["volume"]; ?>"
                     oninput="document.getElementById('er-volume-label').textContent = this.value" />
              <span id="er-volume-label"><?php echo (int)$cfg["volume"]; ?></span>%
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>

  <div class="fppTableWrapper fppTableWrapperAsTable mb-3" id="er-fieldset-announce">
    <div class="fppTableContents">
      <table class="fppSelectableRowTable" style="width:100%;">
        <thead>
          <tr><th colspan="2" style="padding:8px;"><i class="fas fa-fw fa-bullhorn"></i> Announcements</th></tr>
        </thead>
        <tbody>
          <?php if (!$aaInstalled): ?>
            <tr><td colspan="2" style="padding:8px;">
              <p class="text-muted mb-0">
                <i class="fas fa-fw fa-circle-info"></i>
                Scheduled announcements aren't available - they require another
                FPP plugin with a Play/Stop command compatible with this feature
                to be installed first.
              </p>
            </td></tr>
          <?php else: ?>
            <tr><td colspan="2" style="padding:8px;">
              <div class="form-check">
                <input class="form-check-input" type="checkbox" name="announce_enabled" id="er-announce-enabled" value="1" <?php echo $cfg["announce"]["enabled"] ? "checked" : ""; ?> />
                <label class="form-check-label" for="er-announce-enabled">Play an Announcement Assistant slot during after-hours playback</label>
              </div>
            </td></tr>
            <tr>
              <td class="py-1" style="padding:8px; width:160px;">Slot</td>
              <td class="py-1" style="padding:8px;">
                <select name="announce_slot" class="form-control form-control-sm" style="max-width:320px;">
                  <option value="">-- select --</option>
                  <?php foreach ($aaSlots as $slot): ?>
                    <option value="<?php echo $slot["index"]; ?>" <?php echo ((string)$cfg["announce"]["slot"] === (string)$slot["index"]) ? "selected" : ""; ?>>
                      <?php echo htmlspecialchars($slot["label"]); ?>
                    </option>
                  <?php endforeach; ?>
                </select>
              </td>
            </tr>
            <tr>
              <td class="py-1" style="padding:8px;">Timing</td>
              <td class="py-1" style="padding:8px;">
                <div class="d-flex gap-3 flex-wrap">
                  <div class="form-check">
                    <input class="form-check-input" type="radio" name="announce_mode" id="er-announce-mode-cadence" value="cadence" <?php echo $cfg["announce"]["mode"] === "cadence" ? "checked" : ""; ?> onclick="erShowAnnounceMode()" />
                    <label class="form-check-label" for="er-announce-mode-cadence">Every N minutes</label>
                  </div>
                  <div class="form-check">
                    <input class="form-check-input" type="radio" name="announce_mode" id="er-announce-mode-times" value="times" <?php echo $cfg["announce"]["mode"] === "times" ? "checked" : ""; ?> onclick="erShowAnnounceMode()" />
                    <label class="form-check-label" for="er-announce-mode-times">Specific times</label>
                  </div>
                </div>
              </td>
            </tr>
            <tr id="er-announce-cadence-row">
              <td class="py-1" style="padding:8px;">Every</td>
              <td class="py-1" style="padding:8px;">
                <div class="input-group input-group-sm" style="max-width:160px;">
                  <input type="number" class="form-control form-control-sm" name="announce_cadenceMinutes" min="1" step="1" value="<?php echo (int)$cfg["announce"]["cadenceMinutes"]; ?>" />
                  <span class="input-group-text">minutes</span>
                </div>
              </td>
            </tr>
            <tr id="er-announce-times-row">
              <td class="py-1" style="padding:8px;">Times (24h)</td>
              <td class="py-1" style="padding:8px;">
                <textarea name="announce_times" class="form-control form-control-sm" rows="3" style="max-width:320px;"
                          placeholder="One per line, e.g. 22:15&#10;23:00&#10;23:45"><?php echo htmlspecialchars(implode("\n", $cfg["announce"]["times"])); ?></textarea>
              </td>
            </tr>
          <?php endif; ?>
        </tbody>
      </table>
    </div>
  </div>

  <div class="fppTableWrapper fppTableWrapperAsTable mb-3" id="er-fieldset-rotation">
    <div class="fppTableContents">
      <table class="fppSelectableRowTable" style="width:100%;">
        <thead>
          <tr><th colspan="2" style="padding:8px;"><i class="fas fa-fw fa-clock-rotate-left"></i> Source Rotation (Premium)</th></tr>
        </thead>
        <tbody>
          <tr><td colspan="2" style="padding:8px;">
            <div class="form-check">
              <input class="form-check-input" type="checkbox" name="rotation_enabled" id="er-rotation-enabled" value="1" <?php echo $cfg["rotation"]["enabled"] ? "checked" : ""; ?> />
              <label class="form-check-label" for="er-rotation-enabled">Play a different source depending on the day/time, instead of always the one picked in Source above</label>
            </div>
            <p class="small text-muted mt-2 mb-0">
              <i class="fas fa-fw fa-circle-info"></i>
              Each row plays its chosen source during the checked days and
              time window. An end time earlier than the start time wraps
              past midnight (e.g. 22:00-06:00). If no row matches right
              now, the Source picked above plays instead.
            </p>
          </td></tr>
          <tr><td colspan="2" style="padding:8px;">
            <div id="er-rotation-rows"></div>
            <button type="button" class="er-btn er-btn-secondary mt-2" onclick="erAddRotationRow()"><i class="fas fa-fw fa-plus"></i> Add Rotation Entry</button>
            <input type="hidden" name="rotation_entries_json" id="er-rotation-json" />
          </td></tr>
        </tbody>
      </table>
    </div>
  </div>

  <div class="fppTableWrapper fppTableWrapperAsTable mb-3" id="er-fieldset-fallback">
    <div class="fppTableContents">
      <table class="fppSelectableRowTable" style="width:100%;">
        <thead>
          <tr><th colspan="2" style="padding:8px;"><i class="fas fa-fw fa-shield-halved"></i> Source Fallback (Premium)</th></tr>
        </thead>
        <tbody>
          <tr><td colspan="2" style="padding:8px;">
            <div class="form-check">
              <input class="form-check-input" type="checkbox" name="fallback_enabled" id="er-fallback-enabled" value="1" <?php echo $cfg["fallback"]["enabled"] ? "checked" : ""; ?> />
              <label class="form-check-label" for="er-fallback-enabled">If a source fails to start (or dies mid-play), automatically try the next one in this order</label>
            </div>
            <p class="small text-muted mt-2 mb-0">
              <i class="fas fa-fw fa-circle-info"></i>
              Checked roughly every 30 seconds. Put Network Share or TuneIn
              last as a guaranteed backstop, since neither depends on an
              external account being reachable.
            </p>
          </td></tr>
          <?php
            $sourceLabels = [
              "" => "-- none --",
              "customstream" => "Internet Radio (URL)",
              "netshare" => "Network Share",
              "tunein" => "TuneIn",
              "pandora" => "Pandora",
              "spotify" => "Spotify",
            ];
            $chain = $cfg["fallback"]["chain"];
          ?>
          <?php for ($i = 1; $i <= 5; $i++): $picked = $chain[$i - 1] ?? ""; ?>
            <tr>
              <td class="py-1" style="padding:8px; width:160px;">Priority <?php echo $i; ?></td>
              <td class="py-1" style="padding:8px;">
                <select name="fallback_priority_<?php echo $i; ?>" class="form-control form-control-sm" style="max-width:280px;">
                  <?php foreach ($sourceLabels as $val => $label): ?>
                    <option value="<?php echo htmlspecialchars($val); ?>" <?php echo $picked === $val ? "selected" : ""; ?>><?php echo htmlspecialchars($label); ?></option>
                  <?php endforeach; ?>
                </select>
              </td>
            </tr>
          <?php endfor; ?>
        </tbody>
      </table>
    </div>
  </div>

  <div class="fppTableWrapper fppTableWrapperAsTable mb-3" id="er-fieldset-license">
    <div class="fppTableContents">
      <table class="fppSelectableRowTable" style="width:100%;">
        <thead>
          <tr><th colspan="2" style="padding:8px;"><i class="fas fa-fw fa-key"></i> License (Premium)</th></tr>
        </thead>
        <tbody>
          <tr><td colspan="2" style="padding:8px;">
            <?php if ($hasLicenseKey): ?>
              <p class="mb-0"><i class="fas fa-fw fa-circle-check" style="color:#198754;"></i> License key on file. Premium features (Pandora, Spotify, Source Rotation, Source Fallback) are unlocked.</p>
            <?php else: ?>
              <p class="mb-0">
                <strong><?php echo $trialHoursRemaining; ?> premium hours remaining</strong>
                out of a 10-hour trial (only counts while Pandora or Spotify are
                actually playing - TuneIn is always free and doesn't use any of
                this).
              </p>
            <?php endif; ?>
          </td></tr>
          <tr>
            <td class="py-1" style="padding:8px; width:160px;">License Key</td>
            <td class="py-1" style="padding:8px;">
              <input type="text" class="form-control form-control-sm" name="license_key" style="max-width:320px;" value="<?php echo htmlspecialchars($cfg["license"]["key"]); ?>" />
            </td>
          </tr>
          <tr><td colspan="2" style="padding:8px;">
            <button type="button" class="er-btn" onclick="erSave()">
              <i class="fas fa-fw fa-floppy-disk"></i> Save Key
            </button>
            <p class="small text-muted mt-2 mb-0">
              Registered above at <strong><?php echo htmlspecialchars($cfg["license"]["email"]); ?></strong> -
              paste your license key here once you have one. Encore Radio
              itself never links to a purchase page (not allowed by the FPP
              plugin guidelines).
            </p>
          </td></tr>
        </tbody>
      </table>
    </div>
  </div>

  <div id="er-save" class="mb-3">
    <button type="button" class="er-btn er-btn-success" onclick="erSave()"><i class="fas fa-fw fa-floppy-disk"></i> Save</button>
    <button type="button" class="er-btn" onclick="erStart()"><i class="fas fa-fw fa-play"></i> Start Now</button>
    <button type="button" class="er-btn er-btn-secondary" onclick="erStop()"><i class="fas fa-fw fa-stop"></i> Stop</button>
    <span id="erStatus" class="ms-2"></span>
  </div>
</fieldset>
</form>

<script>
  const ER_PLUGIN_BASE =
    (typeof pluginBase !== 'undefined' && pluginBase)
      ? pluginBase
      : 'plugin.php?plugin=fpp-EncoreRadio&';
  const ER_BASE = ER_PLUGIN_BASE + 'nopage=1&page=';

  function erUrl(rel) {
    return ER_BASE + 'www/' + rel;
  }

  async function erReadJson(res) {
    const text = await res.text();
    try { return JSON.parse(text); }
    catch (e) {
      return { status: "ERROR", message: "Non-JSON response (wrong URL). First 200 chars:\n" + text.slice(0, 200) };
    }
  }

  function erSetStatus(msg) {
    const el = document.getElementById('erStatus');
    if (el) el.textContent = msg || "";
  }

  function erShowSourceSection() {
    const source = document.querySelector('input[name="source"]:checked');
    const val = source ? source.value : "";
    document.getElementById('er-customstream-section').style.display = (val === 'customstream') ? 'table-row' : 'none';
    document.getElementById('er-netshare-section').style.display = (val === 'netshare') ? 'table-row' : 'none';
    document.getElementById('er-tunein-section').style.display = (val === 'tunein') ? 'table-row' : 'none';
    document.getElementById('er-pandora-section').style.display = (val === 'pandora') ? 'table-row' : 'none';
    document.getElementById('er-spotify-section').style.display = (val === 'spotify') ? 'table-row' : 'none';
  }
  document.querySelectorAll('input[name="source"]').forEach(function (el) {
    el.addEventListener('change', erShowSourceSection);
  });
  erShowSourceSection();

  function erToggleNetsharePassword() {
    const el = document.getElementById('er-netshare-password');
    if (el.value === '__unchanged__') el.value = '';
    el.type = (el.type === 'password') ? 'text' : 'password';
  }

  function erToggleSpotifySecret() {
    const el = document.getElementById('er-spotify-secret');
    if (el.value === '__unchanged__') el.value = '';
    el.type = (el.type === 'password') ? 'text' : 'password';
  }

  function erConnectSpotify() {
    window.location.href = erUrl('spotify_auth.php');
  }

  async function erSearchSpotify() {
    const q = document.getElementById('er-spotify-search').value.trim();
    const resultsDiv = document.getElementById('er-spotify-results');
    resultsDiv.innerHTML = 'Searching...';

    const res = await fetch(erUrl('search_spotify.php') + '&q=' + encodeURIComponent(q), { cache: 'no-store' });
    const j = await erReadJson(res);
    if (j.status !== 'OK' || !j.results || !j.results.length) {
      resultsDiv.innerHTML = j.message || 'No playlists found.';
      return;
    }

    resultsDiv.innerHTML = j.message ? ('<div class="small text-muted mb-1">' + j.message + '</div>') : '';
    j.results.forEach(function (pl) {
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'er-btn';
      btn.style.display = 'block';
      btn.style.margin = '4px 0';
      btn.textContent = (pl.mine ? '★ ' : '') + pl.name + ' (' + pl.trackCount + ' tracks)';
      btn.onclick = function () {
        document.getElementById('er-spotify-playlistUri').value = pl.uri;
        document.getElementById('er-spotify-playlistName').value = pl.name;
        document.getElementById('er-spotify-selected-name').textContent = pl.name;
      };
      resultsDiv.appendChild(btn);
    });
  }

  async function erUseSpotifyLink() {
    const input = document.getElementById('er-spotify-link');
    const link = input.value.trim();
    const resultsDiv = document.getElementById('er-spotify-results');
    if (!link) { resultsDiv.innerHTML = 'Paste a playlist link first.'; return; }
    resultsDiv.innerHTML = 'Looking up...';

    const res = await fetch(erUrl('spotify_playlist_lookup.php') + '&url=' + encodeURIComponent(link), { cache: 'no-store' });
    const j = await erReadJson(res);
    if (j.status !== 'OK') {
      resultsDiv.innerHTML = j.message || 'Could not look up that playlist.';
      return;
    }
    document.getElementById('er-spotify-playlistUri').value = j.uri;
    document.getElementById('er-spotify-playlistName').value = j.name;
    document.getElementById('er-spotify-selected-name').textContent = j.name;
    resultsDiv.innerHTML = '';
    const found = document.createElement('div');
    found.className = 'small';
    found.style.color = '#198754';
    found.innerHTML = '<i class="fas fa-fw fa-circle-check"></i> ';
    found.appendChild(document.createTextNode('Found "' + j.name + '" (' + j.trackCount + ' tracks) - selected below.'));
    resultsDiv.appendChild(found);
    input.value = '';
  }

  // --- Source Rotation (premium) --------------------------------------
  var erRotationEntries = <?php echo json_encode($cfg["rotation"]["entries"]); ?>;
  var ER_ROTATION_DAYS = [
    ['mon', 'M'], ['tue', 'T'], ['wed', 'W'], ['thu', 'T'], ['fri', 'F'], ['sat', 'S'], ['sun', 'S']
  ];
  var ER_ROTATION_SOURCES = [
    ['customstream', 'Internet Radio (URL)'], ['netshare', 'Network Share'],
    ['tunein', 'TuneIn'], ['pandora', 'Pandora'], ['spotify', 'Spotify']
  ];

  function erRenderRotationRows() {
    var container = document.getElementById('er-rotation-rows');
    container.innerHTML = '';
    erRotationEntries.forEach(function (entry, idx) {
      var row = document.createElement('div');
      row.className = 'd-flex gap-2 flex-wrap align-items-center mb-2 pb-2';
      row.style.borderBottom = '1px solid rgba(128,128,128,0.25)';

      var daysWrap = document.createElement('div');
      daysWrap.className = 'd-flex gap-1';
      ER_ROTATION_DAYS.forEach(function (d) {
        var lbl = document.createElement('label');
        lbl.className = 'small text-center';
        lbl.style.width = '20px';
        lbl.title = d[0];
        var cb = document.createElement('input');
        cb.type = 'checkbox';
        cb.checked = entry.days.indexOf(d[0]) !== -1;
        cb.onchange = function () {
          var i = entry.days.indexOf(d[0]);
          if (cb.checked && i === -1) entry.days.push(d[0]);
          else if (!cb.checked && i !== -1) entry.days.splice(i, 1);
        };
        lbl.appendChild(document.createElement('br'));
        lbl.insertBefore(cb, lbl.firstChild);
        lbl.appendChild(document.createTextNode(d[1]));
        daysWrap.appendChild(lbl);
      });

      var startInput = document.createElement('input');
      startInput.type = 'time';
      startInput.className = 'form-control form-control-sm';
      startInput.style.width = '110px';
      startInput.value = entry.startTime || '22:00';
      startInput.onchange = function () { entry.startTime = startInput.value; };

      var toLabel = document.createElement('span');
      toLabel.className = 'small text-muted';
      toLabel.textContent = 'to';

      var endInput = document.createElement('input');
      endInput.type = 'time';
      endInput.className = 'form-control form-control-sm';
      endInput.style.width = '110px';
      endInput.value = entry.endTime || '23:00';
      endInput.onchange = function () { entry.endTime = endInput.value; };

      var sourceSelect = document.createElement('select');
      sourceSelect.className = 'form-control form-control-sm';
      sourceSelect.style.width = '180px';
      ER_ROTATION_SOURCES.forEach(function (s) {
        var opt = document.createElement('option');
        opt.value = s[0];
        opt.textContent = s[1];
        if (entry.source === s[0]) opt.selected = true;
        sourceSelect.appendChild(opt);
      });
      if (!entry.source) entry.source = ER_ROTATION_SOURCES[2][0]; // tunein
      sourceSelect.onchange = function () { entry.source = sourceSelect.value; };

      var removeBtn = document.createElement('button');
      removeBtn.type = 'button';
      removeBtn.className = 'er-btn er-btn-danger';
      removeBtn.innerHTML = '<i class="fas fa-fw fa-trash"></i>';
      removeBtn.onclick = function () {
        erRotationEntries.splice(idx, 1);
        erRenderRotationRows();
      };

      row.appendChild(daysWrap);
      row.appendChild(startInput);
      row.appendChild(toLabel);
      row.appendChild(endInput);
      row.appendChild(sourceSelect);
      row.appendChild(removeBtn);
      container.appendChild(row);
    });
  }

  function erAddRotationRow() {
    erRotationEntries.push({ days: [], startTime: '22:00', endTime: '23:00', source: 'tunein' });
    erRenderRotationRows();
  }

  erRenderRotationRows();

  function erShowAnnounceMode() {
    const mode = document.querySelector('input[name="announce_mode"]:checked');
    const val = mode ? mode.value : "cadence";
    const cadenceRow = document.getElementById('er-announce-cadence-row');
    const timesRow = document.getElementById('er-announce-times-row');
    if (cadenceRow) cadenceRow.style.display = (val === 'cadence') ? 'table-row' : 'none';
    if (timesRow) timesRow.style.display = (val === 'times') ? 'table-row' : 'none';
  }
  erShowAnnounceMode();

  function erTogglePassword() {
    const el = document.getElementById('er-pandora-password');
    if (el.value === '__unchanged__') el.value = '';
    el.type = (el.type === 'password') ? 'text' : 'password';
  }

  async function erSearchTuneIn() {
    const q = document.getElementById('er-tunein-search').value.trim();
    const resultsDiv = document.getElementById('er-tunein-results');
    if (!q) { resultsDiv.innerHTML = ''; return; }
    resultsDiv.innerHTML = 'Searching...';

    const res = await fetch(erUrl('search_tunein.php') + '&q=' + encodeURIComponent(q), { cache: 'no-store' });
    const j = await erReadJson(res);
    if (j.status !== 'OK' || !j.results || !j.results.length) {
      resultsDiv.innerHTML = 'No stations found.';
      return;
    }

    resultsDiv.innerHTML = '';
    j.results.forEach(function (station) {
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'er-btn';
      btn.style.display = 'block';
      btn.style.margin = '4px 0';
      btn.textContent = station.name;
      btn.onclick = function () {
        document.getElementById('er-tunein-stationId').value = station.id;
        document.getElementById('er-tunein-stationName').value = station.name;
        document.getElementById('er-tunein-streamUrl').value = station.streamUrl;
        document.getElementById('er-tunein-selected-name').textContent = station.name;
      };
      resultsDiv.appendChild(btn);
    });
  }

  async function erSignUp() {
    const statusEl = document.getElementById('er-signup-status');
    const emailEl = document.getElementById('er-signup-email');
    const email = emailEl.value.trim();
    if (!email) { statusEl.textContent = "Enter an email address first."; return; }
    statusEl.textContent = "Registering...";
    const res = await fetch(erUrl('license_register.php'), {
      method: 'POST',
      body: new URLSearchParams({ email }),
      cache: 'no-store'
    });
    const j = await erReadJson(res);
    if (j.status === 'OK') {
      statusEl.textContent = j.message || "Registered!";
      // Reload so the page re-renders with everything unlocked - simpler
      // and more reliable than trying to un-disable the whole fieldset
      // and re-run every PHP-derived default in place with JS.
      setTimeout(function () { window.location.reload(); }, 800);
    } else {
      statusEl.textContent = j.message || "Something went wrong.";
    }
  }

  async function erSave() {
    erSetStatus("Saving...");
    document.getElementById('er-rotation-json').value = JSON.stringify(erRotationEntries);
    const form = document.getElementById('erForm');
    const fd = new FormData(form);
    const res = await fetch(erUrl('save.php'), { method: 'POST', body: fd, cache: 'no-store' });
    const j = await erReadJson(res);
    erSetStatus(j.message || j.status || "OK");
    return j;
  }

  async function erStart() {
    // Save first - otherwise "Start Now" plays whatever was last saved to
    // disk, not whatever's currently picked/typed on the page (e.g. a
    // playlist just selected via search/link but never explicitly saved).
    const saveResult = await erSave();
    if (saveResult.status && saveResult.status !== 'OK') {
      erSetStatus("Not started - save failed: " + (saveResult.message || saveResult.status));
      return;
    }
    erSetStatus("Starting...");
    const res = await fetch(erUrl('start.php'), { cache: 'no-store' });
    const j = await erReadJson(res);
    erSetStatus(j.ok ? "Started." : ("Error: " + (j.error || "Start script exited with no output - check EncoreRadio.log")));
  }

  async function erStop() {
    erSetStatus("Stopping...");
    const res = await fetch(erUrl('stop.php'), { cache: 'no-store' });
    const j = await erReadJson(res);
    erSetStatus(j.ok ? "Stopped." : ("Error: " + (j.error || "unknown")));
  }

  // --- First-run guided tour -----------------------------------------
  // Same coach-mark approach as fpp-plugin-RemoteBackup's config.php:
  // steps top to bottom through this page's own sections, a spotlight +
  // arrow + popup card, auto-shown once, replayable, toggleable off.
  var ER_TOUR_STEPS = [
    {
      selector: '#er-fieldset-source',
      title: 'Pick a Source',
      text: 'A custom internet radio URL, a network share of your own ' +
        'music, and TuneIn are all free. Pandora (a genre/artist station) ' +
        'and Spotify (your own custom playlist) are both premium features ' +
        '- 10 free trial hours, then a license key.'
    },
    {
      selector: '#er-fieldset-volume',
      title: 'Volume',
      text: 'Sets the level Encore Radio plays at. If you also use ' +
        'Announcement Assistant, announcements duck down from this level ' +
        'and back up automatically.'
    },
    {
      selector: '#er-fieldset-announce',
      title: 'Announcements',
      text: 'Optional. If Announcement Assistant is installed, pick one of ' +
        'its slots and a schedule (every N minutes, or specific times) to ' +
        'get radio-station-style announcements layered over the stream ' +
        'automatically - no need to add separate FPP schedule entries for it.'
    },
    {
      selector: '#er-fieldset-license',
      title: 'License (Premium)',
      text: 'Tracks your 10-hour Pandora/Spotify trial (TuneIn never counts ' +
        'against it). Register your email so we can reach you before it ' +
        'runs out, and enter a license key here once you have one - ' +
        'nothing on this page ever links to a purchase page.'
    },
    {
      selector: '#er-save',
      title: 'Save, Start Now, Stop',
      text: 'Save your settings, or use Start Now / Stop to test right ' +
        'from here. For actual after-hours use, add two FPP Schedule ' +
        'entries calling the "Encore Radio - Start" and "Encore Radio - ' +
        'Stop" commands instead - that\'s it, you\'re done!'
    }
  ];
  var erTourIndex = -1;
  var erTourReposition = null;

  function erTourBuildDom() {
    if (document.getElementById('er-tour-popup')) return;
    var hl = document.createElement('div');
    hl.id = 'er-tour-highlight';
    var arrow = document.createElement('div');
    arrow.id = 'er-tour-arrow';
    var popup = document.createElement('div');
    popup.id = 'er-tour-popup';
    popup.innerHTML =
      '<div style="padding:1rem;">' +
      '<div class="small text-muted mb-1" id="er-tour-step-of"></div>' +
      '<div class="fw-bold mb-1" id="er-tour-title"></div>' +
      '<div class="mb-2" id="er-tour-text"></div>' +
      '<div class="d-flex justify-content-between gap-2">' +
      '<button type="button" class="er-btn er-btn-secondary" id="er-tour-back">Back</button>' +
      '<button type="button" class="er-btn er-btn-secondary" id="er-tour-skip">Skip Tour</button>' +
      '<button type="button" class="er-btn" id="er-tour-next">Next</button>' +
      '</div></div>';
    document.body.appendChild(hl);
    document.body.appendChild(arrow);
    document.body.appendChild(popup);
    document.getElementById('er-tour-back').addEventListener('click', function () { erTourGo(erTourIndex - 1); });
    document.getElementById('er-tour-next').addEventListener('click', function () { erTourGo(erTourIndex + 1); });
    document.getElementById('er-tour-skip').addEventListener('click', erTourEnd);
  }

  function erTourStart() {
    erTourBuildDom();
    erTourGo(0);
  }

  function erTourGo(index) {
    if (index < 0) return;
    if (index >= ER_TOUR_STEPS.length) { erTourEnd(); return; }
    erTourIndex = index;
    var step = ER_TOUR_STEPS[index];
    var target = document.querySelector(step.selector);
    if (!target) { erTourGo(index + 1); return; }
    document.getElementById('er-tour-step-of').textContent = 'Step ' + (index + 1) + ' of ' + ER_TOUR_STEPS.length;
    document.getElementById('er-tour-title').textContent = step.title;
    document.getElementById('er-tour-text').textContent = step.text;
    document.getElementById('er-tour-back').disabled = index === 0;
    document.getElementById('er-tour-next').textContent = (index === ER_TOUR_STEPS.length - 1) ? 'Finish' : 'Next';

    target.scrollIntoView({ behavior: 'smooth', block: 'center' });
    clearTimeout(erTourReposition);
    erTourReposition = setTimeout(erTourPosition, 260);
  }

  function erTourPosition() {
    var step = ER_TOUR_STEPS[erTourIndex];
    var target = step && document.querySelector(step.selector);
    if (!target) return;
    var rect = target.getBoundingClientRect();
    var pad = 6;
    var hl = document.getElementById('er-tour-highlight');
    hl.style.top = (rect.top - pad) + 'px';
    hl.style.left = (rect.left - pad) + 'px';
    hl.style.width = (rect.width + pad * 2) + 'px';
    hl.style.height = (rect.height + pad * 2) + 'px';

    var popup = document.getElementById('er-tour-popup');
    var arrow = document.getElementById('er-tour-arrow');
    var popupW = popup.offsetWidth || 320;
    var spaceBelow = window.innerHeight - rect.bottom;
    var below = spaceBelow >= 170 || spaceBelow >= rect.top;
    var left = Math.max(8, Math.min(rect.left, window.innerWidth - popupW - 8));
    popup.style.left = left + 'px';
    if (below) {
      popup.style.top = (rect.bottom + pad + 12) + 'px';
      popup.style.bottom = '';
    } else {
      popup.style.bottom = (window.innerHeight - rect.top + pad + 12) + 'px';
      popup.style.top = '';
    }
    var arrowLeft = Math.max(left + 14, Math.min(rect.left + rect.width / 2 - 9, left + popupW - 26));
    arrow.style.left = arrowLeft + 'px';
    arrow.className = below ? 'er-tour-arrow-above' : 'er-tour-arrow-below';
    if (below) { arrow.style.top = (rect.bottom + pad) + 'px'; arrow.style.bottom = ''; }
    else { arrow.style.bottom = (window.innerHeight - rect.top + pad) + 'px'; arrow.style.top = ''; }
  }

  function erTourEnd() {
    erTourIndex = -1;
    ['er-tour-highlight', 'er-tour-arrow', 'er-tour-popup'].forEach(function (id) {
      var el = document.getElementById(id);
      if (el) el.remove();
    });
    fetch(erUrl('mark_onboarding_seen.php'), { method: 'POST', cache: 'no-store' }).catch(function () {});
  }

  window.addEventListener('resize', function () { if (erTourIndex >= 0) erTourPosition(); });
  window.addEventListener('scroll', function () { if (erTourIndex >= 0) erTourPosition(); }, true);

  document.getElementById('er-onboarding-replay').addEventListener('click', function (e) {
    e.preventDefault();
    erTourStart();
  });

  if (!<?php echo $cfg["ui"]["onboardingSeen"] ? "true" : "false"; ?> &&
      document.getElementById('er-onboardingTourEnabled').checked) {
    erTourStart();
  }
</script>
