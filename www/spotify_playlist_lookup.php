<?php
declare(strict_types=1);
ini_set('display_errors', '0');
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

// Resolve a pasted Spotify playlist link/URI directly to a playlist -
// covers picking a public playlist someone shared with a link, which is
// often faster than typing keywords into search_spotify.php, and also
// reaches playlists that keyword search just doesn't surface well.

$configFile = "/home/fpp/media/config/encoreradio.json";
$input = trim((string)($_GET['url'] ?? ''));

function respond($status, $data = [], $message = "") {
  echo json_encode(array_merge(["status" => $status, "message" => $message], $data));
  exit;
}

if ($input === "") {
  respond("ERROR", [], "Paste a Spotify playlist link first.");
}

// Accepts open.spotify.com/playlist/<id>[?...], spotify:playlist:<id>, or
// a bare 22-char playlist ID.
$playlistId = "";
if (preg_match('#open\.spotify\.com/playlist/([A-Za-z0-9]+)#', $input, $m)) {
  $playlistId = $m[1];
} elseif (preg_match('#^spotify:playlist:([A-Za-z0-9]+)$#', $input, $m)) {
  $playlistId = $m[1];
} elseif (preg_match('#^[A-Za-z0-9]{15,30}$#', $input)) {
  $playlistId = $input;
}
if ($playlistId === "") {
  respond("ERROR", [], "That doesn't look like a Spotify playlist link, URI, or ID.");
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

$scriptDir = dirname(__DIR__) . "/scripts";
$token = trim((string)shell_exec("bash " . escapeshellarg("{$scriptDir}/spotify_token.sh") . " 2>/dev/null"));
if ($token === "") {
  respond("ERROR", [], "Could not get a valid Spotify access token - try reconnecting.");
}

// "items" is this endpoint's current field name for track count (Spotify
// renamed it from "tracks" at some point - see search_spotify.php).
$ch = curl_init("https://api.spotify.com/v1/playlists/{$playlistId}?fields=name,uri,items(total)");
curl_setopt_array($ch, [
  CURLOPT_RETURNTRANSFER => true,
  CURLOPT_HTTPHEADER => ["Authorization: Bearer {$token}"],
  CURLOPT_TIMEOUT => 10,
]);
$response = curl_exec($ch);
$httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
curl_close($ch);

$data = json_decode((string)$response, true);
if ($httpCode !== 200 || !is_array($data) || empty($data["uri"])) {
  respond("ERROR", [], "Couldn't look up that playlist (HTTP {$httpCode}) - it may be private, deleted, or the link is wrong.");
}

respond("OK", [
  "uri" => $data["uri"],
  "name" => (string)($data["name"] ?? "Untitled playlist"),
  "trackCount" => $data["items"]["total"] ?? 0,
]);
