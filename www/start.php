<?php
declare(strict_types=1);

header('Content-Type: application/json');

// Dispatches through FPP's own command API (POST /api/command/{name},
// executed by fppd itself, which already runs as root) rather than
// exec()'ing the script directly from this PHP-FPM process, which runs
// as the unprivileged `fpp` user - confirmed on real hardware that mount
// (needed for the Network Share source) fails under that path, and the
// FPP plugin guidelines don't allow working around that with `sudo` in
// application code ("install/hook scripts already run as root" - the
// same is true of Commands; see scripts/backends/netshare_folder.sh).
//
// FPP's own Command protocol doesn't propagate the script's actual exit
// code or stdout back through this call (by design - Commands are meant
// to be fire-and-forget; the Result it returns is just a fixed
// "<name> complete" string regardless of the script's real outcome). It
// DOES genuinely wait for the script to fully finish before responding -
// confirmed on real hardware: ScriptCommand::run() (FalconChristmas/fpp,
// Plugins.cpp) forks the script and blocks the request thread on
// waitpid() for its entire duration, which for us can legitimately be
// several seconds (mounting a network share, Spotify API calls, walking
// a Fallback chain) - so the timeout here has to be generous, not the
// couple of seconds that would be normal for a simple API call.
$ch = curl_init('http://localhost/api/command/' . rawurlencode('Encore Radio - Start'));
curl_setopt_array($ch, [
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_POST => true,
    CURLOPT_HTTPHEADER => ['Content-Type: application/json'],
    CURLOPT_POSTFIELDS => '[]',
    CURLOPT_TIMEOUT => 60,
]);
$response = curl_exec($ch);
$httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
$curlError = curl_error($ch);
curl_close($ch);

$dispatchOk = ($httpCode === 200);

if (!$dispatchOk) {
    echo json_encode(['ok' => false, 'error' => "Could not dispatch Start (HTTP {$httpCode}): " . ($response !== false && $response !== '' ? $response : $curlError)]);
    exit;
}

echo json_encode(['ok' => true, 'message' => 'Start dispatched.']);
