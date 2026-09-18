<?php
declare(strict_types=1);
ini_set('display_errors', '0');
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

// Matches scripts/er_premium_gate.sh's / license_register.php's LICENSE_SERVER_BASE.
$licenseServerBase = "https://encoreradio-license.nscilingo.workers.dev/api";

function respond($ok, $msg) {
  echo json_encode(["status" => $ok ? "OK" : "ERROR", "message" => $msg]);
  exit;
}

$scriptDir = dirname(__DIR__) . "/scripts";
$hwid = trim((string)shell_exec("bash " . escapeshellarg("{$scriptDir}/er_hwid.sh") . " 2>/dev/null"));
if ($hwid === "" || $hwid === "unknown") {
  respond(false, "Could not determine this device's hardware ID.");
}

$ch = curl_init("{$licenseServerBase}/resend");
curl_setopt_array($ch, [
  CURLOPT_RETURNTRANSFER => true,
  CURLOPT_POST => true,
  CURLOPT_HTTPHEADER => ["Content-Type: application/json"],
  CURLOPT_POSTFIELDS => json_encode(["hwid" => $hwid]),
  CURLOPT_TIMEOUT => 8,
]);
$response = curl_exec($ch);
$httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
$curlError = curl_error($ch);
curl_close($ch);

if ($httpCode === 200) {
  respond(true, "Sent! Check your inbox (and spam folder) in a few minutes.");
}

$serverMsg = null;
$decoded = json_decode((string)$response, true);
if (is_array($decoded) && !empty($decoded["message"])) {
  $serverMsg = $decoded["message"];
}

if ($httpCode === 429) {
  respond(false, $serverMsg ?: "Please wait a few minutes before requesting another resend.");
}
if ($httpCode === 404) {
  respond(false, $serverMsg ?: "This device isn't registered with the license server yet - try Get Started again.");
}

respond(false, $serverMsg ?: ("Could not reach the license server. (" . ($curlError ?: "HTTP {$httpCode}") . ")"));
