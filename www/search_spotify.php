<?php
declare(strict_types=1);
ini_set('display_errors', '0');
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

// Search the owner's own playlists (including private ones - the global
// Search API below only ever returns public playlists) plus, when a query
// is typed, Spotify's global public-playlist catalog too - covers both
// "pick one of my own playlists" and "find some public holiday/lounge
// playlist I don't own," which is what actually makes Spotify the richer
// premium tier over TuneIn/Pandora's fixed-station model.

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

function spotifyGet($url, $token) {
  $ch = curl_init($url);
  curl_setopt_array($ch, [
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_HTTPHEADER => ["Authorization: Bearer {$token}"],
    CURLOPT_TIMEOUT => 10,
  ]);
  $response = curl_exec($ch);
  $httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
  curl_close($ch);
  $data = json_decode((string)$response, true);
  return [$httpCode, is_array($data) ? $data : null];
}

[$httpCode, $data] = spotifyGet("https://api.spotify.com/v1/me/playlists?limit=50", $token);
if ($httpCode !== 200 || $data === null) {
  respond("ERROR", [], "Spotify playlist request failed (HTTP {$httpCode})");
}

$results = [];
$seenUris = [];
foreach (($data["items"] ?? []) as $pl) {
  $name = (string)($pl["name"] ?? "");
  if ($query !== "" && strpos(strtolower($name), $query) === false) continue;
  $uri = (string)($pl["uri"] ?? "");
  if ($uri === "" || isset($seenUris[$uri])) continue;
  $seenUris[$uri] = true;
  $results[] = [
    "uri" => $uri,
    "name" => $name,
    "trackCount" => $pl["tracks"]["total"] ?? 0,
    "mine" => true,
  ];
}

// Global catalog search (public playlists only) - only worth doing once
// there's an actual query; browsing the owner's own list above already
// covers the empty-query case.
if ($query !== "") {
  $searchUrl = "https://api.spotify.com/v1/search?type=playlist&limit=20&q=" . urlencode($query);
  [$searchHttpCode, $searchData] = spotifyGet($searchUrl, $token);
  if ($searchHttpCode === 200 && $searchData !== null) {
    foreach (($searchData["playlists"]["items"] ?? []) as $pl) {
      if (!is_array($pl)) continue; // Spotify's search results can include null entries
      $uri = (string)($pl["uri"] ?? "");
      if ($uri === "" || isset($seenUris[$uri])) continue;
      $seenUris[$uri] = true;
      $owner = (string)($pl["owner"]["display_name"] ?? "");
      $results[] = [
        "uri" => $uri,
        "name" => (string)($pl["name"] ?? "") . ($owner !== "" ? " (by {$owner})" : ""),
        "trackCount" => $pl["tracks"]["total"] ?? 0,
        "mine" => false,
      ];
    }
  }
}

respond("OK", $results);
