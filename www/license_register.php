<?php
declare(strict_types=1);
ini_set('display_errors', '0');
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

// Registering does unlock Pandora/Spotify/Rotation (see www/save.php's
// $premiumUnlocked - registered OR a license key), but doesn't gate the
// free sources, and the trial/license *check* itself
// (scripts/er_premium_gate.sh) still runs entirely off a purely local
// counter, independent of whether an email was ever saved. Saves the
// email locally either way, then makes one best-effort, email-only
// network call: no hardware ID, no usage data, nothing about this device
// at all. That call gets a welcome email and a fixed day-3/7/14 reminder
// schedule going (skipped once an active license exists for the email),
// replacing the old usage-threshold nudge that required reporting
// per-device usage to trigger - see the license-server repo's README
// ("Reminder schedule") for the server side of this.
$licenseServerBase = "https://encoreradio-license.nscilingo.workers.dev/api";

$configFile = "/home/fpp/media/plugindata/fpp-EncoreRadio/encoreradio.json";
require_once __DIR__ . "/er_config_lock.php";

function erRespond($ok, $msg) {
  echo json_encode(["status" => $ok ? "OK" : "ERROR", "message" => $msg]);
  exit;
}

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
  http_response_code(405);
  erRespond(false, "POST required");
}

$email = trim((string)($_POST["email"] ?? ""));
if ($email === "" || !filter_var($email, FILTER_VALIDATE_EMAIL)) {
  erRespond(false, "Enter a valid email address first.");
}

$lock = erConfigLockAuto($configFile);

$cfg = [];
if (file_exists($configFile)) {
  $j = json_decode(@file_get_contents($configFile), true);
  if (is_array($j)) $cfg = $j;
}

$cfg["license"]["email"] = $email;
$cfg["license"]["registered"] = true;

$tmp = $configFile . ".tmp";
@file_put_contents($tmp, json_encode($cfg, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n");
@rename($tmp, $configFile);
@chmod($configFile, 0600);

// Released explicitly rather than left to the shutdown-function backstop -
// the network call just below is best-effort and can take the full curl
// timeout; the lock must not be held across it.
erConfigUnlock($lock);

// Best-effort: the local save above already succeeded regardless of
// whether this reaches the server or times out.
$ch = curl_init("{$licenseServerBase}/register");
curl_setopt_array($ch, [
  CURLOPT_RETURNTRANSFER => true,
  CURLOPT_POST => true,
  CURLOPT_HTTPHEADER => ["Content-Type: application/json"],
  CURLOPT_POSTFIELDS => json_encode(["email" => $email]),
  CURLOPT_TIMEOUT => 8,
]);
@curl_exec($ch);
curl_close($ch);

erRespond(true, "Saved! A welcome email is on its way, with reminder emails over the next two weeks if you haven't entered a license key by then.");
