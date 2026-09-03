<?php
declare(strict_types=1);

// Encore Radio - Spotify OAuth step 1: redirect the browser to Spotify's
// own authorize page. Uses the owner's own Developer App (client ID) - see
// README for why: each install has a different local address, and Spotify
// requires an exact registered redirect URI, so there's no single shared
// app that could work for every install.

$configFile = "/home/fpp/media/config/encoreradio.json";
$cfg = [];
if (file_exists($configFile)) {
  $j = json_decode(@file_get_contents($configFile), true);
  if (is_array($j)) $cfg = $j;
}
$clientId = trim((string)($cfg["spotify"]["clientId"] ?? ""));

if ($clientId === "") {
  http_response_code(400);
  echo "Spotify Client ID not configured - save it on the Encore Radio page first.";
  exit;
}

function encoreRadioRedirectUri(): string {
  $scheme = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off') ? 'https' : 'http';
  $host = $_SERVER['HTTP_HOST'] ?? 'localhost';
  return "{$scheme}://{$host}/plugin.php?plugin=fpp-EncoreRadio&nopage=1&page=www/spotify_callback.php";
}

$redirectUri = encoreRadioRedirectUri();

// Scopes: playlist-read-private (search/list the owner's own playlists),
// user-read-playback-state + user-modify-playback-state (find the
// Raspotify device and start/stop/volume playback on it).
$scopes = "playlist-read-private user-read-playback-state user-modify-playback-state";

$state = bin2hex(random_bytes(16));
session_start();
$_SESSION["encoreradio_spotify_state"] = $state;

$params = http_build_query([
  "client_id" => $clientId,
  "response_type" => "code",
  "redirect_uri" => $redirectUri,
  "scope" => $scopes,
  "state" => $state,
]);

header("Location: https://accounts.spotify.com/authorize?{$params}");
exit;
