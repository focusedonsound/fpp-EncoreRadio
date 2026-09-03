<?php
declare(strict_types=1);
ini_set('display_errors', '0');
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

// Matches scripts/er_premium_gate.sh's LICENSE_SERVER_BASE.
$licenseServerBase = "https://encoreradio-license.nscilingo.workers.dev/api";

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
// Registered is the soft gate for the whole plugin now (see save.php) -
// set it as soon as we have a syntactically valid email, regardless of
// whether the license server was reachable just now. The point is
// capturing the email; a transient network failure here shouldn't lock
// someone out of the plugin entirely, and the next usage report retries
// the server-side registration anyway (see er_track_usage.sh).
$cfg["license"]["registered"] = true;

$tmp = $configFile . ".tmp";
@file_put_contents($tmp, json_encode($cfg, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n");
@rename($tmp, $configFile);

if ($httpCode === 200) {
  respond(true, "Registered! We'll email you when your trial is running low, and if it runs out.");
}

respond(true, "Registered locally - we'll keep trying to reach the license server in the background, so you're all set either way. (" . ($curlError ?: "HTTP {$httpCode}") . ")");
