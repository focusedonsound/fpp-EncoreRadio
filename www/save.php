<?php
ini_set('display_errors', '0');
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

$configFile = "/home/fpp/media/config/encoreradio.json";

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
    "customstream" => ["name" => "", "streamUrl" => ""],
    "netshare" => ["sharePath" => "", "username" => "", "password" => "", "folder" => ""],
    "rotation" => ["enabled" => false, "entries" => []],
    "fallback" => ["enabled" => false, "chain" => []],
    "tunein" => ["stationId" => "", "stationName" => "", "streamUrl" => ""],
    "pandora" => ["username" => "", "password" => "", "stationId" => "", "stationName" => ""],
    "spotify" => ["clientId" => "", "clientSecret" => "", "accessToken" => "", "refreshToken" => "", "tokenExpiresAt" => 0, "playlistUri" => "", "playlistName" => "", "deviceName" => ""],
    "announce" => ["enabled" => false, "slot" => "", "mode" => "cadence", "cadenceMinutes" => 15, "times" => []],
    "license" => ["email" => "", "registered" => false, "key" => "", "trialSecondsUsed" => 0],
    "ui" => ["onboardingSeen" => false],
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

// Registration (just an email, nothing else) is the one soft gate for the
// whole plugin - enforced here, not just cosmetically greyed out in the
// UI, since nothing downstream (TuneIn included) can be configured
// without a successful save. Registration itself happens through
// license_register.php, which sets this flag directly - this endpoint
// only checks it, it never sets it.
if (!($cfg["license"]["registered"] ?? false)) {
  respond(false, "Register your email at the top of the page first - it's the only thing required before you can use Encore Radio.");
}

$source = trim((string)($_POST["source"] ?? ""));
if (!in_array($source, ["", "customstream", "netshare", "tunein", "pandora", "spotify"], true)) {
  respond(false, "Invalid source: $source");
}
$cfg["source"] = $source;

$volume = isset($_POST["volume"]) ? (int)$_POST["volume"] : $cfg["volume"];
if ($volume < 0) $volume = 0;
if ($volume > 100) $volume = 100;
$cfg["volume"] = $volume;

$cfg["customstream"]["name"]      = trim((string)($_POST["customstream_name"] ?? $cfg["customstream"]["name"]));
$cfg["customstream"]["streamUrl"] = trim((string)($_POST["customstream_streamUrl"] ?? $cfg["customstream"]["streamUrl"]));

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

// Rotation (premium) - entries are built client-side into a JSON array
// (day checkboxes + start/end time + source per row don't map cleanly
// onto plain form fields) and posted as one hidden field.
$cfg["rotation"]["enabled"] = isset($_POST["rotation_enabled"]) && $_POST["rotation_enabled"] === "1";
$validSources = ["customstream", "netshare", "tunein", "pandora", "spotify"];
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

// Fallback (premium) - five ordered priority dropdowns rather than a
// drag-and-drop list, simplest reliable UI for a handful of fixed options.
$cfg["fallback"]["enabled"] = isset($_POST["fallback_enabled"]) && $_POST["fallback_enabled"] === "1";
$fallbackChain = [];
for ($i = 1; $i <= 5; $i++) {
  $pick = trim((string)($_POST["fallback_priority_{$i}"] ?? ""));
  if ($pick === "" || !in_array($pick, $validSources, true)) continue;
  if (in_array($pick, $fallbackChain, true)) continue; // no duplicates
  $fallbackChain[] = $pick;
}
$cfg["fallback"]["chain"] = $fallbackChain;

// License (M4) - email/key are the only fields this form edits;
// trialSecondsUsed is only ever written by er_track_usage.sh.
$cfg["license"]["email"] = trim((string)($_POST["license_email"] ?? $cfg["license"]["email"]));
$cfg["license"]["key"] = trim((string)($_POST["license_key"] ?? $cfg["license"]["key"]));

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

respond(true, "Saved.");
