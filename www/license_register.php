<?php
declare(strict_types=1);
ini_set('display_errors', '0');
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

// Purely local: saves the operator's email for their own reference (and
// so the page can show "Registered as ...") and nothing else. No network
// call, no hardware ID - registering doesn't gate anything and doesn't
// power any server-side notification, so there's nothing here that
// needs to leave the device. See www/save.php and
// scripts/er_premium_gate.sh for how the trial/license gate actually
// works, entirely separately from this.

$configFile = "/home/fpp/media/plugindata/fpp-EncoreRadio/encoreradio.json";

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

$cfg["license"]["email"] = $email;
$cfg["license"]["registered"] = true;

$tmp = $configFile . ".tmp";
@file_put_contents($tmp, json_encode($cfg, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n");
@rename($tmp, $configFile);
@chmod($configFile, 0600);

respond(true, "Saved.");
