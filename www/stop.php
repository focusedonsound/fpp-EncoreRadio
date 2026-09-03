<?php
declare(strict_types=1);

header('Content-Type: application/json');

$SCRIPT = __DIR__ . '/../commands/er_cmd_stop.sh';
if (!file_exists($SCRIPT)) {
    echo json_encode(['ok' => false, 'error' => 'Stop script missing']);
    exit;
}

$cmd = escapeshellcmd($SCRIPT);
$out = [];
$rc  = 0;
exec($cmd . ' 2>&1', $out, $rc);

if ($rc !== 0) {
    echo json_encode(['ok' => false, 'error' => implode("\n", $out)]);
    exit;
}

echo json_encode(['ok' => true, 'message' => implode("\n", $out)]);
