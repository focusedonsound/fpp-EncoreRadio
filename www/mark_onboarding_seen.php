<?php
declare(strict_types=1);
ini_set('display_errors', '0');
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

$configFile = "/home/fpp/media/config/encoreradio.json";

$cfg = [];
if (file_exists($configFile)) {
  $j = json_decode(@file_get_contents($configFile), true);
  if (is_array($j)) $cfg = $j;
}
$cfg["ui"]["onboardingSeen"] = true;

$tmp = $configFile . ".tmp";
if (@file_put_contents($tmp, json_encode($cfg, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n") === false
    || !@rename($tmp, $configFile)) {
  echo json_encode(["status" => "ERROR", "message" => "Failed to save"]);
  exit;
}

echo json_encode(["status" => "OK"]);
