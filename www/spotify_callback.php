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

$configFile = "/home/fpp/media/config/encoreradio.json";

function renderResult(bool $ok, string $message): void {
  $color = $ok ? "#2a7" : "#c33";
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
  renderResult(false, "Spotify returned an error: {$error}");
}
if (!$code || !$nonce || $nonce !== $expectedNonce) {
  renderResult(false, "Invalid or missing OAuth state - please try connecting again.");
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
  renderResult(false, "Spotify Client ID/Secret missing from config - save them on the Encore Radio page first.");
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
  renderResult(false, "Token exchange failed: " . (is_array($data) ? ($data["error_description"] ?? $response) : $response));
}

$cfg["spotify"]["accessToken"] = $data["access_token"];
$cfg["spotify"]["refreshToken"] = $data["refresh_token"] ?? ($cfg["spotify"]["refreshToken"] ?? "");
$cfg["spotify"]["tokenExpiresAt"] = time() + (int)($data["expires_in"] ?? 3600);

$tmp = $configFile . ".tmp";
if (@file_put_contents($tmp, json_encode($cfg, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n") === false
    || !@rename($tmp, $configFile)) {
  renderResult(false, "Got tokens from Spotify but failed to save them to config.");
}

renderResult(true, "Your Spotify account is now connected. You can search and pick a playlist on the Encore Radio page. Don't forget the separate one-time step of pairing the Raspotify Connect device via your phone's Spotify app if you haven't already.");
