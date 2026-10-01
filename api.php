<?php
// Encore Radio - FPP header status indicator (top bar icon while playing).
// Mirrors the generic plugin-header-indicator pattern documented by
// OnlineDynamic/BackgroundMusicFPP-Plugin (HEADER_INDICATOR.md) - FPP core
// auto-discovers a `headerIndicator` GET endpoint on any plugin's api.php
// and polls it on every status refresh, no other wiring needed.

include_once("/opt/fpp/www/common.php");

function getEndpointsfppEncoreRadio() {
    $result = array();

    $ep = array(
        'method' => 'GET',
        'endpoint' => 'headerIndicator',
        'callback' => 'erHeaderIndicator');
    array_push($result, $ep);

    $ep = array(
        'method' => 'GET',
        'endpoint' => 'stations',
        'callback' => 'erStations');
    array_push($result, $ep);

    return $result;
}

// GET /api/plugin/fpp-EncoreRadio/stations
// Names of the Internet Radio stations (active + Saved Stations, de-duped
// by URL, same order as the failover chain) - feeds the Station dropdown
// on the "Encore Radio - Play Station" command.
function erStations() {
    $cfg = json_decode(@file_get_contents("/home/fpp/media/plugindata/fpp-EncoreRadio/encoreradio.json"), true);
    $cs = (is_array($cfg) && is_array($cfg["customstream"] ?? null)) ? $cfg["customstream"] : array();

    $chain = array(array("name" => $cs["name"] ?? "", "streamUrl" => $cs["streamUrl"] ?? ""));
    if (is_array($cs["saved"] ?? null)) {
        $chain = array_merge($chain, $cs["saved"]);
    }

    $names = array();
    $seenUrls = array();
    foreach ($chain as $e) {
        $url = trim((string)($e["streamUrl"] ?? ""));
        if ($url === "" || isset($seenUrls[$url])) {
            continue;
        }
        $seenUrls[$url] = true;
        $name = trim((string)($e["name"] ?? ""));
        $name = $name !== "" ? $name : $url;
        if (!in_array($name, $names, true)) {
            $names[] = $name;
        }
    }

    return json($names);
}

// GET /api/plugin/fpp-EncoreRadio/headerIndicator
function erHeaderIndicator() {
    $stateFile = "/home/fpp/media/plugins/fpp-EncoreRadio/state/active.json";
    if (!file_exists($stateFile)) {
        return json(null);
    }

    $active = json_decode(@file_get_contents($stateFile), true);
    if (!is_array($active)) {
        return json(null);
    }

    $label = trim((string)($active["label"] ?? ""));
    $tooltip = $label !== "" ? "Encore Radio: {$label}" : "Encore Radio Playing";

    return json(array(
        "visible" => true,
        "icon" => "fa-broadcast-tower",
        "color" => "#1a6eb5",
        "tooltip" => $tooltip,
        "link" => "/plugin.php?plugin=fpp-EncoreRadio&page=www/index.php",
        "animate" => "pulse"
    ));
}
