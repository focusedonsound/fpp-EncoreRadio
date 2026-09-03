<?php
$configFile = "/home/fpp/media/config/encoreradio.json";

function loadConfig($path) {
  $cfg = [
    "source" => "",
    "relay" => ["port" => 8123],
    "volume" => 70,
    "tunein" => ["stationId" => "", "stationName" => "", "streamUrl" => ""],
    "pandora" => ["username" => "", "password" => "", "stationId" => "", "stationName" => ""],
    "spotify" => ["clientId" => "", "clientSecret" => "", "accessToken" => "", "refreshToken" => "", "tokenExpiresAt" => 0, "playlistUri" => "", "playlistName" => "", "deviceName" => ""],
    "announce" => ["enabled" => false, "slot" => "", "mode" => "cadence", "cadenceMinutes" => 15, "times" => []],
    "license" => ["email" => "", "key" => "", "trialHoursUsed" => 0],
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
?>

<h1 class="title">Encore Radio</h1>
<p>
  Keep the show's radio station going after the lights go dark. Pick a
  source below - TuneIn or Pandora are free; Spotify (your own custom
  playlist) is a premium feature. Add FPP Schedule entries calling
  <strong>Encore Radio - Start</strong> / <strong>Encore Radio - Stop</strong>
  for your after-hours window, and you're set.
</p>

<form id="erForm" onsubmit="return false;">

  <fieldset id="er-fieldset-source" style="margin-bottom:20px;">
    <legend>Source</legend>

    <label style="margin-right:20px;">
      <input type="radio" name="source" value="tunein" <?php echo $cfg["source"] === "tunein" ? "checked" : ""; ?> />
      TuneIn
    </label>
    <label style="margin-right:20px;">
      <input type="radio" name="source" value="pandora" <?php echo $cfg["source"] === "pandora" ? "checked" : ""; ?> />
      Pandora
    </label>
    <label>
      <input type="radio" name="source" value="spotify" <?php echo $cfg["source"] === "spotify" ? "checked" : ""; ?> />
      Spotify (premium)
    </label>

    <div id="er-tunein-section" style="margin-top:14px; display:none;">
      <div>
        <input type="text" id="er-tunein-search" placeholder="Search TuneIn stations..." style="width:320px;" />
        <button type="button" class="buttons btn-outline-primary" onclick="erSearchTuneIn()">Search</button>
      </div>
      <div id="er-tunein-results" style="margin-top:8px;"></div>
      <div style="margin-top:8px;">
        Selected station:
        <strong id="er-tunein-selected-name"><?php echo htmlspecialchars($cfg["tunein"]["stationName"]); ?></strong>
      </div>
      <input type="hidden" name="tunein_stationId" id="er-tunein-stationId" value="<?php echo htmlspecialchars($cfg["tunein"]["stationId"]); ?>" />
      <input type="hidden" name="tunein_stationName" id="er-tunein-stationName" value="<?php echo htmlspecialchars($cfg["tunein"]["stationName"]); ?>" />
      <input type="hidden" name="tunein_streamUrl" id="er-tunein-streamUrl" value="<?php echo htmlspecialchars($cfg["tunein"]["streamUrl"]); ?>" />
    </div>

    <div id="er-pandora-section" style="margin-top:14px; display:none;">
      <table class="fppTable" style="width:100%; max-width:500px;">
        <tr>
          <td>Pandora Username</td>
          <td><input type="text" name="pandora_username" value="<?php echo htmlspecialchars($cfg["pandora"]["username"]); ?>" style="width:100%;" /></td>
        </tr>
        <tr>
          <td>Pandora Password</td>
          <td>
            <input type="password" name="pandora_password" id="er-pandora-password"
                   value="<?php echo $cfg["pandora"]["password"] !== "" ? "__unchanged__" : ""; ?>"
                   style="width:85%;" />
            <button type="button" class="buttons btn-outline-secondary" onclick="erTogglePassword()">Show</button>
          </td>
        </tr>
        <tr>
          <td>Station ID</td>
          <td><input type="text" name="pandora_stationId" value="<?php echo htmlspecialchars($cfg["pandora"]["stationId"]); ?>" style="width:100%;" /></td>
        </tr>
        <tr>
          <td>Station Name (label only)</td>
          <td><input type="text" name="pandora_stationName" value="<?php echo htmlspecialchars($cfg["pandora"]["stationName"]); ?>" style="width:100%;" /></td>
        </tr>
      </table>
      <p style="font-size:0.9em; color:#888;">
        Station ID is the number from your Pandora station's URL. Pianobar
        prints available station IDs to the Encore Radio log on first login
        if you're not sure which to use.
      </p>
    </div>

    <div id="er-spotify-section" style="margin-top:14px; display:none;">
      <?php if (!$raspotifyInstalled): ?>
        <p style="color:#c33;">
          Raspotify (the Spotify Connect client this plugin uses) wasn't
          installed successfully - check the install log. Your device's
          processor architecture may not be supported.
        </p>
      <?php endif; ?>

      <p style="font-size:0.9em; color:#888;">
        Spotify needs two separate one-time setup steps:
        <strong>1)</strong> connect your own Spotify Developer App below (so
        Encore Radio can search your playlists and start playback), and
        <strong>2)</strong> pair this device once via your phone's Spotify
        app on the same network (open Spotify, tap the device/Connect icon,
        and select
        "<code><?php echo htmlspecialchars($cfg["spotify"]["deviceName"] ?: '(set after install)'); ?></code>").
        Neither step is needed again after that.
      </p>

      <table class="fppTable" style="width:100%; max-width:600px;">
        <tr>
          <td>Spotify Client ID</td>
          <td><input type="text" name="spotify_clientId" value="<?php echo htmlspecialchars($cfg["spotify"]["clientId"]); ?>" style="width:100%;" /></td>
        </tr>
        <tr>
          <td>Spotify Client Secret</td>
          <td>
            <input type="password" name="spotify_clientSecret" id="er-spotify-secret"
                   value="<?php echo $cfg["spotify"]["clientSecret"] !== "" ? "__unchanged__" : ""; ?>"
                   style="width:85%;" />
            <button type="button" class="buttons btn-outline-secondary" onclick="erToggleSpotifySecret()">Show</button>
          </td>
        </tr>
      </table>
      <p style="font-size:0.9em; color:#888;">
        Create a free app at
        <a href="https://developer.spotify.com/dashboard" target="_blank">developer.spotify.com/dashboard</a>,
        then add this exact Redirect URI to it:
        <code id="er-spotify-redirect-uri"></code>
      </p>

      <div style="margin:10px 0;">
        <button type="button" class="buttons btn-outline-primary" onclick="erSave().then(erConnectSpotify)">
          Save &amp; Connect to Spotify
        </button>
        <span style="margin-left:10px;">
          <?php echo $spotifyConnected ? "✅ Connected" : "Not connected yet"; ?>
        </span>
      </div>

      <?php if ($spotifyConnected): ?>
        <div>
          <input type="text" id="er-spotify-search" placeholder="Search your playlists..." style="width:320px;" />
          <button type="button" class="buttons btn-outline-primary" onclick="erSearchSpotify()">Search</button>
        </div>
        <div id="er-spotify-results" style="margin-top:8px;"></div>
        <div style="margin-top:8px;">
          Selected playlist:
          <strong id="er-spotify-selected-name"><?php echo htmlspecialchars($cfg["spotify"]["playlistName"]); ?></strong>
        </div>
      <?php endif; ?>
      <input type="hidden" name="spotify_playlistUri" id="er-spotify-playlistUri" value="<?php echo htmlspecialchars($cfg["spotify"]["playlistUri"]); ?>" />
      <input type="hidden" name="spotify_playlistName" id="er-spotify-playlistName" value="<?php echo htmlspecialchars($cfg["spotify"]["playlistName"]); ?>" />
    </div>
  </fieldset>

  <fieldset id="er-fieldset-volume" style="margin-bottom:20px;">
    <legend>Volume</legend>
    <input type="range" name="volume" id="er-volume" min="0" max="100" step="1"
           value="<?php echo (int)$cfg["volume"]; ?>"
           oninput="document.getElementById('er-volume-label').textContent = this.value" />
    <span id="er-volume-label"><?php echo (int)$cfg["volume"]; ?></span>%
  </fieldset>

  <fieldset id="er-fieldset-announce" style="margin-bottom:20px;">
    <legend>Announcements</legend>

    <?php if (!$aaInstalled): ?>
      <p style="color:#888;">
        <a href="https://github.com/focusedonsound/fpp-AnnouncementAssistant" target="_blank">Announcement Assistant</a>
        isn't installed, so scheduled announcements aren't available yet.
        Install it if you want radio-station-style announcements layered
        over the stream.
      </p>
    <?php else: ?>
      <label>
        <input type="checkbox" name="announce_enabled" value="1" <?php echo $cfg["announce"]["enabled"] ? "checked" : ""; ?> />
        Play an Announcement Assistant slot during after-hours playback
      </label>

      <table class="fppTable" style="width:100%; max-width:600px; margin-top:10px;">
        <tr>
          <td>Slot</td>
          <td>
            <select name="announce_slot" style="width:100%;">
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
          <td>Timing</td>
          <td>
            <label style="margin-right:16px;">
              <input type="radio" name="announce_mode" value="cadence" <?php echo $cfg["announce"]["mode"] === "cadence" ? "checked" : ""; ?> onclick="erShowAnnounceMode()" />
              Every N minutes
            </label>
            <label>
              <input type="radio" name="announce_mode" value="times" <?php echo $cfg["announce"]["mode"] === "times" ? "checked" : ""; ?> onclick="erShowAnnounceMode()" />
              Specific times
            </label>
          </td>
        </tr>
        <tr id="er-announce-cadence-row">
          <td>Every</td>
          <td>
            <input type="number" name="announce_cadenceMinutes" min="1" step="1"
                   value="<?php echo (int)$cfg["announce"]["cadenceMinutes"]; ?>" style="width:80px;" /> minutes
          </td>
        </tr>
        <tr id="er-announce-times-row">
          <td>Times (24h)</td>
          <td>
            <textarea name="announce_times" rows="3" style="width:100%;"
                      placeholder="One per line, e.g. 22:15&#10;23:00&#10;23:45"><?php echo htmlspecialchars(implode("\n", $cfg["announce"]["times"])); ?></textarea>
          </td>
        </tr>
      </table>
    <?php endif; ?>
  </fieldset>

  <div id="er-save" style="margin-top:12px;">
    <button type="button" class="buttons btn-outline-success" onclick="erSave()">Save</button>
    <button type="button" class="buttons btn-outline-primary" onclick="erStart()">Start Now</button>
    <button type="button" class="buttons btn-outline-secondary" onclick="erStop()">Stop</button>
    <span id="erStatus" style="margin-left:10px;"></span>
  </div>
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
    document.getElementById('er-tunein-section').style.display = (val === 'tunein') ? 'block' : 'none';
    document.getElementById('er-pandora-section').style.display = (val === 'pandora') ? 'block' : 'none';
    document.getElementById('er-spotify-section').style.display = (val === 'spotify') ? 'block' : 'none';
  }
  document.querySelectorAll('input[name="source"]').forEach(function (el) {
    el.addEventListener('change', erShowSourceSection);
  });
  erShowSourceSection();

  const redirectUriEl = document.getElementById('er-spotify-redirect-uri');
  if (redirectUriEl) {
    redirectUriEl.textContent = window.location.origin +
      '/plugin.php?plugin=fpp-EncoreRadio&nopage=1&page=www/spotify_callback.php';
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

    resultsDiv.innerHTML = '';
    j.results.forEach(function (pl) {
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'buttons btn-outline-primary';
      btn.style.display = 'block';
      btn.style.margin = '4px 0';
      btn.textContent = pl.name + ' (' + pl.trackCount + ' tracks)';
      btn.onclick = function () {
        document.getElementById('er-spotify-playlistUri').value = pl.uri;
        document.getElementById('er-spotify-playlistName').value = pl.name;
        document.getElementById('er-spotify-selected-name').textContent = pl.name;
      };
      resultsDiv.appendChild(btn);
    });
  }

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
      btn.className = 'buttons btn-outline-primary';
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

  async function erSave() {
    erSetStatus("Saving...");
    const form = document.getElementById('erForm');
    const fd = new FormData(form);
    const res = await fetch(erUrl('save.php'), { method: 'POST', body: fd, cache: 'no-store' });
    const j = await erReadJson(res);
    erSetStatus(j.message || j.status || "OK");
  }

  async function erStart() {
    erSetStatus("Starting...");
    const res = await fetch(erUrl('start.php'), { cache: 'no-store' });
    const j = await erReadJson(res);
    erSetStatus(j.ok ? "Started." : ("Error: " + (j.error || "unknown")));
  }

  async function erStop() {
    erSetStatus("Stopping...");
    const res = await fetch(erUrl('stop.php'), { cache: 'no-store' });
    const j = await erReadJson(res);
    erSetStatus(j.ok ? "Stopped." : ("Error: " + (j.error || "unknown")));
  }
</script>
