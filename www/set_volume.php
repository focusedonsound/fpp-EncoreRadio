<?php
declare(strict_types=1);

header('Content-Type: application/json');

// Same GET-must-never-change-state reasoning as start.php: this persists
// a setting and can audibly change live playback, so it must never run on
// a plain page load / forged <img> src.
if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    http_response_code(405);
    echo json_encode(['ok' => false, 'error' => 'POST required']);
    exit;
}

$configFile = "/home/fpp/media/plugindata/fpp-EncoreRadio/encoreradio.json";
require_once __DIR__ . '/er_config_lock.php';

$volume = isset($_POST['volume']) ? (int)$_POST['volume'] : null;
if ($volume === null) {
    echo json_encode(['ok' => false, 'error' => 'volume is required']);
    exit;
}
if ($volume < 0) $volume = 0;
if ($volume > 100) $volume = 100;

// Persist, same atomic-write pattern as save.php - this is deliberately a
// narrow single-field update (not a full save.php call), which only
// shrinks how much a lost update could clobber (just "volume", not the
// whole form) - it doesn't by itself prevent the read-then-write race
// against a concurrent save.php (dragging the slider while Save is also
// in flight). The lock below is what actually closes that.
$lock = erConfigLockAuto($configFile);

$cfg = [];
if (file_exists($configFile)) {
    $j = json_decode(@file_get_contents($configFile), true);
    if (is_array($j)) $cfg = $j;
}
$cfg['volume'] = $volume;

$tmp = $configFile . '.tmp';
$data = json_encode($cfg, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n";
if (@file_put_contents($tmp, $data) === false) {
    erConfigUnlock($lock);
    echo json_encode(['ok' => false, 'error' => "Failed to write temp config: $tmp"]);
    exit;
}
if (!@rename($tmp, $configFile)) {
    @unlink($tmp);
    erConfigUnlock($lock);
    echo json_encode(['ok' => false, 'error' => "Failed to replace config file: $configFile"]);
    exit;
}
@chmod($configFile, 0600);
erConfigUnlock($lock);

// Apply live if something's currently playing (issue #4 - the slider
// used to only take effect on the next restart). Runs as the fpp user
// (this is PHP-FPM, not a root-run FPP Command) - the shared system
// PulseAudio/PipeWire-pulse socket is group-writable to `audio`, which
// fpp is already a member of, so no root/Command dispatch is needed here.
// Backgrounded: er_apply_volume.sh can poll for up to 15s if playback
// only just started, and this request shouldn't hang on that.
$here = dirname(__DIR__) . '/scripts';
exec('nohup bash ' . escapeshellarg("{$here}/er_apply_volume.sh") . ' ' . escapeshellarg((string)$volume)
    . ' > /dev/null 2>&1 &');

echo json_encode(['ok' => true, 'volume' => $volume]);
