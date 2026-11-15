<?php
declare(strict_types=1);
ini_set('display_errors', '0');
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

// POST-only: this logs in to SiriusXM (via the aiosxm proxy) and rebuilds the
// cached channel lineup - a state-changing, credential-using action that must
// never run on a GET, or a plain <img>/<iframe> on any open page could trigger
// a SiriusXM login with no interaction. Same rule as start.php/stop.php.
if (($_SERVER['REQUEST_METHOD'] ?? 'GET') !== 'POST') {
    http_response_code(405);
    echo json_encode(["ok" => false, "error" => "POST required"]);
    exit;
}

$stateFile = "/home/fpp/media/plugins/fpp-EncoreRadio/state/sxm_channels.json";

// Dispatch through FPP's own command API (executed by fppd as root) rather
// than exec()'ing the fetch script from this unprivileged PHP-FPM process -
// the proxy start/login needs the root context the plugin scripts assume, and
// the plugin guidelines don't allow working around that with sudo in app code
// (see start.php for the full rationale). fppd blocks until the script
// finishes, so once this returns 200 the state file below is fresh.
$ch = curl_init('http://localhost/api/command/' . rawurlencode('Encore Radio - Load SiriusXM Channels'));
curl_setopt_array($ch, [
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_POST => true,
    CURLOPT_HTTPHEADER => ['Content-Type: application/json'],
    CURLOPT_POSTFIELDS => '[]',
    // Generous: a cold login + walking ~700 channels can take several seconds.
    CURLOPT_TIMEOUT => 90,
]);
$response = curl_exec($ch);
$httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
$curlError = curl_error($ch);
curl_close($ch);

if ($httpCode !== 200) {
    echo json_encode([
        "ok" => false,
        "error" => "Could not dispatch the channel load (HTTP {$httpCode}): " .
            ($response !== false && $response !== '' ? $response : $curlError),
    ]);
    exit;
}

// Read back what the command wrote. It always writes an {"status":...} object,
// ok or error - surface that straight to the UI.
$raw = @file_get_contents($stateFile);
$data = is_string($raw) ? json_decode($raw, true) : null;
if (!is_array($data)) {
    echo json_encode([
        "ok" => false,
        "error" => "The channel load ran but produced no readable result. Check the Encore Radio log.",
    ]);
    exit;
}

if (($data["status"] ?? "") !== "ok") {
    echo json_encode([
        "ok" => false,
        "error" => (string)($data["message"] ?? "Could not load channels."),
    ]);
    exit;
}

echo json_encode([
    "ok" => true,
    "count" => (int)($data["count"] ?? 0),
    "fetchedAt" => (int)($data["fetchedAt"] ?? 0),
    "channels" => is_array($data["channels"] ?? null) ? $data["channels"] : [],
]);
