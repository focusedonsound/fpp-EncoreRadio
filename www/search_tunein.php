<?php
declare(strict_types=1);
ini_set('display_errors', '0');
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

// TuneIn's public search directory - no login/API key required. Returns a
// simplified list of {id, name, streamUrl} for the UI's search-as-you-type.
$query = trim((string)($_GET['q'] ?? ''));
if ($query === '') {
  echo json_encode(["status" => "OK", "results" => []]);
  exit;
}

$searchUrl = "https://opml.radiotime.com/Search.ashx?query=" . urlencode($query) . "&render=json&formats=mp3,aac,ogg";

$ctx = stream_context_create(["http" => ["timeout" => 5]]);
$body = @file_get_contents($searchUrl, false, $ctx);
if ($body === false) {
  echo json_encode(["status" => "ERROR", "message" => "TuneIn search request failed", "results" => []]);
  exit;
}

// Shorter timeout than the search request above, and a hard cap on how
// many items get checked at all (below) - each item costs its own
// blocking Tune.ashx round-trip, and TuneIn can return far more "audio"
// items than ever resolve a stream URL. Without both caps, one search can
// occupy a PHP-FPM worker for minutes.
$tuneCtx = stream_context_create(["http" => ["timeout" => 2]]);

$json = json_decode($body, true);
$results = [];
$MAX_ITEMS_CHECKED = 25;
$itemsChecked = 0;
if (is_array($json) && isset($json['body']) && is_array($json['body'])) {
  foreach ($json['body'] as $item) {
    if (($item['type'] ?? '') !== 'audio') continue;
    if ($itemsChecked >= $MAX_ITEMS_CHECKED) break;
    $itemsChecked++;
    $guideId = $item['guide_id'] ?? '';
    if ($guideId === '') continue;

    // Resolve the actual stream URL via TuneIn's Tune.ashx for this station id.
    $tuneUrl = "https://opml.radiotime.com/Tune.ashx?id=" . urlencode($guideId) . "&render=json";
    $tuneBody = @file_get_contents($tuneUrl, false, $tuneCtx);
    $streamUrl = "";
    if ($tuneBody !== false) {
      $tuneJson = json_decode($tuneBody, true);
      if (is_array($tuneJson) && isset($tuneJson['body'][0]['url'])) {
        $streamUrl = $tuneJson['body'][0]['url'];
      }
    }
    if ($streamUrl === "") continue;

    $results[] = [
      "id" => $guideId,
      "name" => $item['text'] ?? $guideId,
      "streamUrl" => $streamUrl,
    ];
    if (count($results) >= 15) break;
  }
}

echo json_encode(["status" => "OK", "results" => $results]);
