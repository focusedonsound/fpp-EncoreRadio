<?php
declare(strict_types=1);

// Encore Radio - Spotify OAuth step 2. Spotify itself redirects to the
// license server's fixed HTTPS `/spotify/callback` (see spotify_auth.php
// for why), which bounces the browser straight back here with the code
// appended. Exchange it for an access token + refresh token and store
// them (masked in the UI, same pattern as any other credential field).

// Must match the fixed URL sent as redirect_uri in the original authorize
// request (spotify_auth.php) - Spotify requires the token exchange's
// redirect_uri to match exactly, even though nothing is actually
// redirected there again at this point.
define("ER_SPOTIFY_FIXED_REDIRECT_URI", "https://encoreradio-license.nscilingo.workers.dev/spotify/callback");

$configFile = "/home/fpp/media/plugindata/fpp-EncoreRadio/encoreradio.json";
require_once __DIR__ . "/er_config_lock.php";

function erRenderResult(bool $ok, string $message): void {
  // This page has no FPP header/theme shell around it at all (it's the
  // bare OAuth-redirect landing target, not loaded via plugin.php), so
  // there's no [data-bs-theme] context to actually differ by - the
  // var() fallback is what always renders here. Still using the same
  // Bootstrap semantic colours (with the plugin's own prior shorthand
  // hex as the fallback) rather than a one-off literal, in case this
  // page ever does end up embedded in FPP's shell later.
  $color = $ok ? "var(--bs-success, #2a7)" : "var(--bs-danger, #c33)";
  echo "<h2 style='color:{$color}'>" . ($ok ? "Spotify connected!" : "Spotify connection failed") . "</h2>";
  echo "<p>" . htmlspecialchars($message) . "</p>";
  echo "<p><a href='plugin.php?plugin=fpp-EncoreRadio&page=www/index.php'>Return to Encore Radio</a></p>";
  exit;
}

session_start();
$expectedNonce = $_SESSION["encoreradio_spotify_state"] ?? null;
$nonce = $_GET["nonce"] ?? null;
$code = $_GET["code"] ?? null;
$error = $_GET["error"] ?? null;

if ($error) {
  erRenderResult(false, "Spotify returned an error: {$error}");
}
if (!$code || !$nonce || $nonce !== $expectedNonce) {
  erRenderResult(false, "Invalid or missing OAuth state - please try connecting again.");
}
unset($_SESSION["encoreradio_spotify_state"]);

$cfg = [];
if (file_exists($configFile)) {
  $j = json_decode(@file_get_contents($configFile), true);
  if (is_array($j)) $cfg = $j;
}
$clientId = trim((string)($cfg["spotify"]["clientId"] ?? ""));
$clientSecret = trim((string)($cfg["spotify"]["clientSecret"] ?? ""));
if ($clientId === "" || $clientSecret === "") {
  erRenderResult(false, "Spotify Client ID/Secret missing from config - save them on the Encore Radio page first.");
}

$ch = curl_init("https://accounts.spotify.com/api/token");
curl_setopt_array($ch, [
  CURLOPT_RETURNTRANSFER => true,
  CURLOPT_POST => true,
  CURLOPT_USERPWD => "{$clientId}:{$clientSecret}",
  CURLOPT_POSTFIELDS => http_build_query([
    "grant_type" => "authorization_code",
    "code" => $code,
    "redirect_uri" => ER_SPOTIFY_FIXED_REDIRECT_URI,
  ]),
  CURLOPT_TIMEOUT => 10,
]);
$response = curl_exec($ch);
$httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
curl_close($ch);

$data = json_decode((string)$response, true);
if ($httpCode !== 200 || !is_array($data) || empty($data["access_token"])) {
  erRenderResult(false, "Token exchange failed: " . (is_array($data) ? ($data["error_description"] ?? $response) : $response));
}

// Lock + re-read fresh here, not reuse of the $cfg read before the token
// exchange above - that exchange is a real network round trip (up to the
// 10s CURLOPT_TIMEOUT), plenty of time for a concurrent save.php to have
// written a change this request would otherwise clobber with a now-stale
// snapshot.
$lock = erConfigLockAuto($configFile);
$cfg = [];
if (file_exists($configFile)) {
  $j = json_decode(@file_get_contents($configFile), true);
  if (is_array($j)) $cfg = $j;
}

$cfg["spotify"]["accessToken"] = $data["access_token"];
$cfg["spotify"]["refreshToken"] = $data["refresh_token"] ?? ($cfg["spotify"]["refreshToken"] ?? "");
$cfg["spotify"]["tokenExpiresAt"] = time() + (int)($data["expires_in"] ?? 3600);

$tmp = $configFile . ".tmp";
if (@file_put_contents($tmp, json_encode($cfg, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n") === false
    || !@rename($tmp, $configFile)) {
  erConfigUnlock($lock);
  erRenderResult(false, "Got tokens from Spotify but failed to save them to config.");
}
@chmod($configFile, 0600);
erConfigUnlock($lock);

erRenderResult(true, "Your Spotify account is now connected. You can search and pick a playlist on the Encore Radio page. Don't forget the separate one-time step of pairing the Raspotify Connect device via your phone's Spotify app if you haven't already.");
