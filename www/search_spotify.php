<?php
declare(strict_types=1);
ini_set('display_errors', '0');
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

// Search the owner's OWN playlists (not a global Spotify catalog search) -
// matches the product intent of "pick one of your own custom playlists,"
// the differentiator that makes Spotify the premium tier over TuneIn/
// Pandora's "pick a station" model.

$configFile = "/home/fpp/media/config/encoreradio.json";
$query = strtolower(trim((string)($_GET['q'] ?? '')));

function respond($status, $results, $message = "") {
  echo json_encode(["status" => $status, "results" => $results, "message" => $message]);
  exit;
}

$cfg = [];
if (file_exists($configFile)) {
  $j = json_decode(@file_get_contents($configFile), true);
  if (is_array($j)) $cfg = $j;
}
$refreshToken = trim((string)($cfg["spotify"]["refreshToken"] ?? ""));
if ($refreshToken === "") {
  respond("ERROR", [], "Spotify not connected yet - use the Connect button first.");
}

// Reuse the same token-refresh logic the playback scripts use, rather than
// duplicating the refresh HTTP call here.
$scriptDir = dirname(__DIR__) . "/scripts";
$token = trim((string)shell_exec("bash " . escapeshellarg("{$scriptDir}/spotify_token.sh") . " 2>/dev/null"));
if ($token === "") {
  respond("ERROR", [], "Could not get a valid Spotify access token - try reconnecting.");
}

$ch = curl_init("https://api.spotify.com/v1/me/playlists?limit=50");
curl_setopt_array($ch, [
  CURLOPT_RETURNTRANSFER => true,
  CURLOPT_HTTPHEADER => ["Authorization: Bearer {$token}"],
  CURLOPT_TIMEOUT => 10,
]);
$response = curl_exec($ch);
$httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
curl_close($ch);

$data = json_decode((string)$response, true);
if ($httpCode !== 200 || !is_array($data)) {
  respond("ERROR", [], "Spotify playlist request failed (HTTP {$httpCode})");
}

$results = [];
foreach (($data["items"] ?? []) as $pl) {
  $name = (string)($pl["name"] ?? "");
  if ($query !== "" && strpos(strtolower($name), $query) === false) continue;
  $results[] = [
    "uri" => $pl["uri"] ?? "",
    "name" => $name,
    "trackCount" => $pl["tracks"]["total"] ?? 0,
  ];
}

respond("OK", $results);
