<?php
ini_set('display_errors', '0');
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

$configFile = "/home/fpp/media/plugindata/fpp-EncoreRadio/encoreradio.json";

function respond($ok, $msg, $extra = []) {
  echo json_encode(array_merge([
    "status" => $ok ? "OK" : "ERROR",
    "message" => $msg
  ], $extra));
  exit;
}

function defaultConfig() {
  return [
    "source" => "",
    "relay" => ["port" => 8123],
    "volume" => 70,
    "customstream" => ["name" => "", "streamUrl" => "", "saved" => []],
    "netshare" => ["sharePath" => "", "username" => "", "password" => "", "folder" => ""],
    "rotation" => ["enabled" => false, "entries" => []],
    "fallback" => ["enabled" => false, "chain" => []],
    "tunein" => ["stationId" => "", "stationName" => "", "streamUrl" => ""],
    "pandora" => ["username" => "", "password" => "", "stationId" => "", "stationName" => ""],
    "spotify" => ["clientId" => "", "clientSecret" => "", "accessToken" => "", "refreshToken" => "", "tokenExpiresAt" => 0, "playlistUri" => "", "playlistName" => "", "deviceName" => ""],
    "announce" => ["enabled" => false, "slot" => "", "mode" => "cadence", "cadenceMinutes" => 15, "times" => []],
    "license" => ["email" => "", "registered" => false, "key" => ""],
    "ui" => ["onboardingSeen" => false, "onboardingTourEnabled" => true],
  ];
}

$dir = dirname($configFile);
if (!is_dir($dir)) {
  respond(false, "Config directory missing: $dir");
}
if (!is_writable($dir)) {
  respond(false, "Config directory not writable: $dir");
}

$cfg = defaultConfig();
if (file_exists($configFile)) {
  $j = json_decode(@file_get_contents($configFile), true);
  if (is_array($j)) $cfg = array_replace_recursive($cfg, $j);
}

// License - processed first so a freshly-pasted key can unlock premium
// fields later in this same request, not just after a reload. Email/key
// are the only fields this form edits; trial-hour tracking lives
// entirely separately, in trial_state.json, written only by
// er_track_usage.sh.
$cfg["license"]["email"] = trim((string)($_POST["license_email"] ?? $cfg["license"]["email"]));
$cfg["license"]["key"] = trim((string)($_POST["license_key"] ?? $cfg["license"]["key"]));

// Pandora/Spotify/Rotation (premium) require registration OR an
// existing license key - never a default. Source Fallback is free
// (auto-recovery, not a premium capability), and free sources
// (customstream/netshare/TuneIn, and Announcement scheduling) are never
// gated either. Mirrors index.php's greyed-out fields, but enforced
// here too since a disabled attribute alone doesn't stop a direct POST.
$premiumUnlocked = (bool)($cfg["license"]["registered"] ?? false) || $cfg["license"]["key"] !== "";

$source = trim((string)($_POST["source"] ?? ""));
if (!in_array($source, ["", "customstream", "netshare", "tunein", "pandora", "spotify"], true)) {
  respond(false, "Invalid source: $source");
}
if (in_array($source, ["pandora", "spotify"], true) && !$premiumUnlocked) {
  // Keep whatever source was already configured - don't let a locked
  // source slip through even if the client-side disabled radio was
  // bypassed.
  $source = $cfg["source"];
}
$cfg["source"] = $source;

$volume = isset($_POST["volume"]) ? (int)$_POST["volume"] : $cfg["volume"];
if ($volume < 0) $volume = 0;
if ($volume > 100) $volume = 100;
$cfg["volume"] = $volume;

$cfg["customstream"]["name"]      = trim((string)($_POST["customstream_name"] ?? $cfg["customstream"]["name"]));
$cfg["customstream"]["streamUrl"] = trim((string)($_POST["customstream_streamUrl"] ?? $cfg["customstream"]["streamUrl"]));

// Saved Stations (free) - a little personal library of Internet Radio URLs
// the operator can flip between without retyping. Built client-side into a
// JSON array and posted as one hidden field, same convention as Rotation's
// entries. This is deliberately independent of Rotation/Fallback (keyed
// off the five fixed source *types*, never individual URLs) -
// saving a few stations for yourself is just data entry convenience, not
// the kind of thing worth gating.
$customstreamSaved = [];
$customstreamSavedRaw = json_decode((string)($_POST["customstream_saved_json"] ?? "[]"), true);
if (is_array($customstreamSavedRaw)) {
  foreach ($customstreamSavedRaw as $e) {
    if (!is_array($e)) continue;
    $url = trim((string)($e["streamUrl"] ?? ""));
    if ($url === "") continue;
    $name = trim((string)($e["name"] ?? ""));
    $customstreamSaved[] = ["name" => ($name !== "" ? $name : $url), "streamUrl" => $url];
  }
}
$cfg["customstream"]["saved"] = $customstreamSaved;

$cfg["netshare"]["sharePath"] = trim((string)($_POST["netshare_sharePath"] ?? $cfg["netshare"]["sharePath"]));
$cfg["netshare"]["username"]  = trim((string)($_POST["netshare_username"] ?? $cfg["netshare"]["username"]));
// Only overwrite the stored password if the field was actually changed -
// same masked-field convention as pandora_password/spotify_clientSecret.
$postedSharePassword = (string)($_POST["netshare_password"] ?? "");
if ($postedSharePassword !== "" && $postedSharePassword !== "__unchanged__") {
  $cfg["netshare"]["password"] = $postedSharePassword;
}
$cfg["netshare"]["folder"] = trim((string)($_POST["netshare_folder"] ?? $cfg["netshare"]["folder"]));

$cfg["tunein"]["stationId"]   = trim((string)($_POST["tunein_stationId"] ?? $cfg["tunein"]["stationId"]));
$cfg["tunein"]["stationName"] = trim((string)($_POST["tunein_stationName"] ?? $cfg["tunein"]["stationName"]));
$cfg["tunein"]["streamUrl"]   = trim((string)($_POST["tunein_streamUrl"] ?? $cfg["tunein"]["streamUrl"]));

if ($premiumUnlocked) {
  $cfg["pandora"]["username"]    = trim((string)($_POST["pandora_username"] ?? $cfg["pandora"]["username"]));
  // Only overwrite the stored password if the field was actually changed -
  // the UI sends the literal string below (see index.php) for an unmodified
  // masked field so a save never has to round-trip the real secret to the
  // browser just to redisplay it.
  $postedPassword = (string)($_POST["pandora_password"] ?? "");
  if ($postedPassword !== "" && $postedPassword !== "__unchanged__") {
    $cfg["pandora"]["password"] = $postedPassword;
  }
  $cfg["pandora"]["stationId"]   = trim((string)($_POST["pandora_stationId"] ?? $cfg["pandora"]["stationId"]));
  $cfg["pandora"]["stationName"] = trim((string)($_POST["pandora_stationName"] ?? $cfg["pandora"]["stationName"]));

  // Spotify (premium tier) - only the form-editable fields; accessToken/
  // refreshToken/tokenExpiresAt come from the OAuth callback, deviceName
  // from the installer, and array_replace_recursive above already preserved
  // all of those, so only overwrite the subset this form actually edits.
  $cfg["spotify"]["clientId"] = trim((string)($_POST["spotify_clientId"] ?? $cfg["spotify"]["clientId"]));
  $postedSecret = (string)($_POST["spotify_clientSecret"] ?? "");
  if ($postedSecret !== "" && $postedSecret !== "__unchanged__") {
    $cfg["spotify"]["clientSecret"] = $postedSecret;
  }
  $cfg["spotify"]["playlistUri"] = trim((string)($_POST["spotify_playlistUri"] ?? $cfg["spotify"]["playlistUri"]));
  $cfg["spotify"]["playlistName"] = trim((string)($_POST["spotify_playlistName"] ?? $cfg["spotify"]["playlistName"]));
}
// else: leave $cfg["pandora"]/$cfg["spotify"] exactly as loaded - not
// registered and no license key, so none of this is accepted yet.

$validSources = ["customstream", "netshare", "tunein", "pandora", "spotify"];

if ($premiumUnlocked) {
  // Rotation (premium) - entries are built client-side into a JSON array
  // (day checkboxes + start/end time + source per row don't map cleanly
  // onto plain form fields) and posted as one hidden field.
  $cfg["rotation"]["enabled"] = isset($_POST["rotation_enabled"]) && $_POST["rotation_enabled"] === "1";
  $validDays = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"];
  $rotationEntries = [];
  $rotationRaw = json_decode((string)($_POST["rotation_entries_json"] ?? "[]"), true);
  if (is_array($rotationRaw)) {
    foreach ($rotationRaw as $e) {
      if (!is_array($e)) continue;
      $source = (string)($e["source"] ?? "");
      $start = (string)($e["startTime"] ?? "");
      $end = (string)($e["endTime"] ?? "");
      $days = array_values(array_intersect((array)($e["days"] ?? []), $validDays));
      if (!in_array($source, $validSources, true)) continue;
      if (!preg_match('/^([01]\d|2[0-3]):[0-5]\d$/', $start)) continue;
      if (!preg_match('/^([01]\d|2[0-3]):[0-5]\d$/', $end)) continue;
      if (empty($days)) continue;
      $rotationEntries[] = ["days" => $days, "startTime" => $start, "endTime" => $end, "source" => $source];
    }
  }
  $cfg["rotation"]["entries"] = $rotationEntries;
}
// else: leave $cfg["rotation"] exactly as loaded - Rotation is premium.

// Fallback is free - auto-recovery if a source dies, not a premium
// capability - so it's never gated, unlike Rotation just above. Five
// ordered priority dropdowns rather than a drag-and-drop list, simplest
// reliable UI for a handful of fixed options.
$cfg["fallback"]["enabled"] = isset($_POST["fallback_enabled"]) && $_POST["fallback_enabled"] === "1";
$fallbackChain = [];
for ($i = 1; $i <= 5; $i++) {
  $pick = trim((string)($_POST["fallback_priority_{$i}"] ?? ""));
  if ($pick === "" || !in_array($pick, $validSources, true)) continue;
  if (in_array($pick, $fallbackChain, true)) continue; // no duplicates
  $fallbackChain[] = $pick;
}
$cfg["fallback"]["chain"] = $fallbackChain;

// Announcement Assistant scheduling (M2)
$cfg["announce"]["enabled"] = isset($_POST["announce_enabled"]) && $_POST["announce_enabled"] === "1";
$cfg["announce"]["slot"] = trim((string)($_POST["announce_slot"] ?? $cfg["announce"]["slot"]));

$mode = trim((string)($_POST["announce_mode"] ?? $cfg["announce"]["mode"]));
if (!in_array($mode, ["cadence", "times"], true)) $mode = "cadence";
$cfg["announce"]["mode"] = $mode;

$cadence = isset($_POST["announce_cadenceMinutes"]) ? (int)$_POST["announce_cadenceMinutes"] : $cfg["announce"]["cadenceMinutes"];
if ($cadence < 1) $cadence = 1;
$cfg["announce"]["cadenceMinutes"] = $cadence;

// Times come from a textarea, one HH:MM per line (or comma-separated) -
// simplest input the owner can type freely rather than a multi-row picker.
$timesRaw = (string)($_POST["announce_times"] ?? "");
$times = [];
foreach (preg_split('/[\s,]+/', $timesRaw) as $t) {
  $t = trim($t);
  if ($t !== "" && preg_match('/^([01]\d|2[0-3]):[0-5]\d$/', $t)) {
    $times[] = $t;
  }
}
$cfg["announce"]["times"] = array_values(array_unique($times));

// Atomic write
$tmp = $configFile . ".tmp";
$data = json_encode($cfg, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n";
if (@file_put_contents($tmp, $data) === false) {
  respond(false, "Failed to write temp config: $tmp");
}
if (!@rename($tmp, $configFile)) {
  @unlink($tmp);
  respond(false, "Failed to replace config file: $configFile");
}
@chmod($configFile, 0600);

// Fire-and-forget: only Raspotify's enabled/running state depends on this
// (see scripts/er_sync_spotify_service.sh for why it can't just be set
// unconditionally at install) - a dispatch failure here just means it's
// re-synced on the next save, so it must never fail the save itself.
$ch = curl_init('http://localhost/api/command/' . rawurlencode('Encore Radio - Sync Spotify Service'));
curl_setopt_array($ch, [
  CURLOPT_RETURNTRANSFER => true,
  CURLOPT_POST => true,
  CURLOPT_HTTPHEADER => ['Content-Type: application/json'],
  CURLOPT_POSTFIELDS => '[]',
  CURLOPT_TIMEOUT => 15,
]);
@curl_exec($ch);
curl_close($ch);

respond(true, "Saved.");
