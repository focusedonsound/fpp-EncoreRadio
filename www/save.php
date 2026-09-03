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
    "tunein" => ["stationId" => "", "stationName" => "", "streamUrl" => ""],
    "pandora" => ["username" => "", "password" => "", "stationId" => "", "stationName" => ""],
    "spotify" => ["clientId" => "", "clientSecret" => "", "accessToken" => "", "refreshToken" => "", "tokenExpiresAt" => 0, "playlistUri" => "", "playlistName" => "", "deviceName" => ""],
    "announce" => ["enabled" => false, "slot" => "", "mode" => "cadence", "cadenceMinutes" => 15, "times" => []],
    "license" => ["email" => "", "key" => "", "trialSecondsUsed" => 0],
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


$source = trim((string)($_POST["source"] ?? ""));
if (!in_array($source, ["", "tunein", "pandora", "spotify"], true)) {
  respond(false, "Invalid source: $source");
}
$cfg["source"] = $source;

$volume = isset($_POST["volume"]) ? (int)$_POST["volume"] : $cfg["volume"];
if ($volume < 0) $volume = 0;
if ($volume > 100) $volume = 100;
$cfg["volume"] = $volume;

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
