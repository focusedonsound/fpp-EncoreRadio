<?php
declare(strict_types=1);

// Encore Radio - Spotify OAuth step 1: redirect the browser to Spotify's
// own authorize page. Uses the owner's own Developer App (client ID).
//
// Spotify only accepts a redirect URI that's https:// (or an exact
// 127.0.0.1 loopback) - a plain LAN address like http://192.168.x.x is
// rejected outright, and every Encore Radio install has a different LAN
// address anyway. So every install's Spotify Developer App is configured
// with the SAME fixed HTTPS redirect URI below (the license server), which
// just bounces the browser straight back to this specific device's own
// local callback page (passed here as `state`) with the auth code
// appended - see the license server's `/spotify/callback` handler. The
// token exchange itself still happens entirely on the local device.
define("ER_SPOTIFY_FIXED_REDIRECT_URI", "https://encoreradio-license.nscilingo.workers.dev/spotify/callback");

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

function encoreRadioLocalCallbackUri(): string {
  $scheme = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off') ? 'https' : 'http';
  $host = $_SERVER['HTTP_HOST'] ?? 'localhost';
  return "{$scheme}://{$host}/plugin.php?plugin=fpp-EncoreRadio&nopage=1&page=www/spotify_callback.php";
}

// Scopes: playlist-read-private (search/list the owner's own playlists),
// user-read-playback-state + user-modify-playback-state (find the
// Raspotify device and start/stop/volume playback on it).
$scopes = "playlist-read-private user-read-playback-state user-modify-playback-state";

$nonce = bin2hex(random_bytes(16));
session_start();
$_SESSION["encoreradio_spotify_state"] = $nonce;

$localReturn = encoreRadioLocalCallbackUri() . "?nonce=" . urlencode($nonce);

$params = http_build_query([
  "client_id" => $clientId,
  "response_type" => "code",
  "redirect_uri" => ER_SPOTIFY_FIXED_REDIRECT_URI,
  "scope" => $scopes,
  "state" => $localReturn,
]);

header("Location: https://accounts.spotify.com/authorize?{$params}");
exit;
