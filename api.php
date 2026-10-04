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
    $stateDir = "/home/fpp/media/plugins/fpp-EncoreRadio/state";
    $stateFile = "{$stateDir}/active.json";

    if (file_exists($stateFile)) {
        $active = json_decode(@file_get_contents($stateFile), true);
        if (is_array($active)) {
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
    }

    // No confirmed-active source, but a Start may still be in progress -
    // er_start_source.sh writes this the moment it starts (before the
    // backend/relay/player are even dispatched), via an EXIT trap so it
    // can never outlive the script that wrote it. Real user feedback:
    // some stations take several seconds to connect, with nothing shown
    // anywhere in the meantime it looks indistinguishable from broken -
    // this is the one piece of feedback that exists at all for a Start
    // triggered by an FPP Schedule entry rather than the plugin's own
    // page (which has its own, more detailed JS-side status already).
    $connectingFile = "{$stateDir}/connecting.json";
    if (file_exists($connectingFile)) {
        $connecting = json_decode(@file_get_contents($connectingFile), true);
        if (is_array($connecting)) {
            return json(array(
                "visible" => true,
                "icon" => "fa-circle-notch",
                "color" => "#6c757d",
                "tooltip" => "Encore Radio: connecting…",
                "link" => "/plugin.php?plugin=fpp-EncoreRadio&page=www/index.php",
                // FPP core's BuildPluginHeaderIndicator() applies this
                // string directly as a CSS animation-name (`animate`
                // isn't a special keyword) - "spin" isn't a real
                // keyframe anywhere in FPP's own CSS and would have
                // silently done nothing; "ajax-spin" (fpp.css) is a real
                // 0->360deg rotation, confirmed against the actual
                // current upstream source before using it.
                "animate" => "ajax-spin"
            ));
        }
    }

    return json(null);
}
