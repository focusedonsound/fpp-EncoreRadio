<?php
declare(strict_types=1);

header('Content-Type: application/json');

// See start.php for why this dispatches through FPP's own command API
// instead of exec()'ing the script directly.
$ch = curl_init('http://localhost/api/command/' . rawurlencode('Encore Radio - Stop'));
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
    echo json_encode(['ok' => false, 'error' => "Could not dispatch Stop (HTTP {$httpCode}): " . ($response !== false && $response !== '' ? $response : $curlError)]);
    exit;
}

echo json_encode(['ok' => true, 'message' => 'Stop dispatched.']);
