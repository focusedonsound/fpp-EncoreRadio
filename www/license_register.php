<?php
declare(strict_types=1);
ini_set('display_errors', '0');
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

// PLACEHOLDER SERVER: matches scripts/er_premium_gate.sh's
// LICENSE_SERVER_BASE - not a real endpoint until M5 (a Cloudflare Worker)
// is built. Swap both constants together.
$licenseServerBase = "https://license.focusedonsound.example/api";

$configFile = "/home/fpp/media/config/encoreradio.json";

function respond($ok, $msg) {
  echo json_encode(["status" => $ok ? "OK" : "ERROR", "message" => $msg]);
  exit;
}

$email = trim((string)($_POST["email"] ?? ""));
if ($email === "" || !filter_var($email, FILTER_VALIDATE_EMAIL)) {
  respond(false, "Enter a valid email address first.");
}

$cfg = [];
if (file_exists($configFile)) {
  $j = json_decode(@file_get_contents($configFile), true);
  if (is_array($j)) $cfg = $j;
}

$scriptDir = dirname(__DIR__) . "/scripts";
$hwid = trim((string)shell_exec("bash " . escapeshellarg("{$scriptDir}/er_hwid.sh") . " 2>/dev/null"));
if ($hwid === "" || $hwid === "unknown") {
  respond(false, "Could not determine this device's hardware ID.");
}

$ch = curl_init("{$licenseServerBase}/register");
curl_setopt_array($ch, [
  CURLOPT_RETURNTRANSFER => true,
  CURLOPT_POST => true,
  CURLOPT_HTTPHEADER => ["Content-Type: application/json"],
  CURLOPT_POSTFIELDS => json_encode(["email" => $email, "hwid" => $hwid]),
  CURLOPT_TIMEOUT => 8,
]);
$response = curl_exec($ch);
$httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
$curlError = curl_error($ch);
curl_close($ch);

$cfg["license"]["email"] = $email;

$tmp = $configFile . ".tmp";
@file_put_contents($tmp, json_encode($cfg, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n");
@rename($tmp, $configFile);

if ($httpCode === 200) {
  respond(true, "Registered! You'll get an email when your trial hours are running low.");
}

// The license server doesn't exist yet (M5) - this is expected right now,
// not a bug. Email is still saved locally above so nothing is lost once
// M5 ships and this can be retried.
respond(false, "Couldn't reach the license server (it may not be set up yet) - your email is saved and registration will complete automatically once it is. (" . ($curlError ?: "HTTP {$httpCode}") . ")");
