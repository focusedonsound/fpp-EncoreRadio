<?php
declare(strict_types=1);
ini_set('display_errors', '0');
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

// GET: report what's playing right now on the active SiriusXM channel, for the
// plugin page's live now-playing line. Read-only and safe on a GET - it only
// queries the aiosxm proxy that is ALREADY running (started in root context by
// the playback backend); it starts nothing, uses no credentials, and binds
// nothing. If SiriusXM isn't the active source, there's nothing to report.
//
// aiosxm's GET /now-playing/{channel_id} returns:
//   {channel_id,title,artist,show,is_ad,started_at,image_url}

$pluginData = "/home/fpp/media/plugindata/fpp-EncoreRadio/encoreradio.json";
$stateDir   = "/home/fpp/media/plugins/fpp-EncoreRadio/state";

function er_np_out(array $o): void { echo json_encode($o); exit; }

// 1) Is SiriusXM actually the active source?
$active = json_decode((string)@file_get_contents("{$stateDir}/active.json"), true);
if (!is_array($active) || ($active["source"] ?? "") !== "siriusxm") {
    er_np_out(["playing" => false]);
}

// 2) Which channel id did the backend resolve and start?
$sxm = json_decode((string)@file_get_contents("{$stateDir}/sxm_active.json"), true);
$channelId = is_array($sxm) ? trim((string)($sxm["id"] ?? "")) : "";
$channelName = is_array($sxm) ? trim((string)($sxm["channelName"] ?? ($sxm["channel"] ?? ""))) : "";
if ($channelId === "") {
    // Active, but we don't know the id (older session / state lost). Say we're
    // playing so the UI still shows the SiriusXM label, just without a track.
    er_np_out(["playing" => true, "channelName" => $channelName]);
}

// 3) Proxy port from config (digits only; same default as er_sxm_proxy.sh).
$cfg = json_decode((string)@file_get_contents($pluginData), true);
$port = 0;
if (is_array($cfg) && isset($cfg["siriusxm"]["proxyPort"])) {
    $port = (int)preg_replace('/\D/', '', (string)$cfg["siriusxm"]["proxyPort"]);
}
if ($port <= 0) { $port = 8124; }

// 4) Query the already-running loopback proxy. Short timeout - this is polled.
$url = "http://127.0.0.1:{$port}/now-playing/" . rawurlencode($channelId);
$ch = curl_init($url);
curl_setopt_array($ch, [
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_TIMEOUT => 4,
]);
$body = curl_exec($ch);
$code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
curl_close($ch);

if ($code !== 200 || !is_string($body)) {
    // Proxy momentarily unreachable mid-playback - still "playing", just no
    // track this tick. The UI keeps the last line it had.
    er_np_out(["playing" => true, "channelName" => $channelName]);
}

$np = json_decode($body, true);
if (!is_array($np)) {
    er_np_out(["playing" => true, "channelName" => $channelName]);
}

er_np_out([
    "playing"     => true,
    "channelName" => $channelName,
    "artist"      => (string)($np["artist"] ?? ""),
    "title"       => (string)($np["title"] ?? ""),
    "show"        => (string)($np["show"] ?? ""),
    "isAd"        => (bool)($np["is_ad"] ?? false),
    "imageUrl"    => (string)($np["image_url"] ?? ""),
]);
