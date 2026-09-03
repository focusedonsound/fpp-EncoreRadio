#!/usr/bin/env bash
# Encore Radio - playback backend detection.
#
# Own copy of the same probe Announcement Assistant uses
# (fpp-AnnouncementAssistant/scripts/aa_play.sh): probe fppd's Command API
# rather than branching on FPP version. Whether Stream Slots
# (GStreamer/PipeWire) are actually active is what matters, not which major
# version is installed. Deliberately NOT shared as a library between the two
# plugins (see project decision) - each plugin keeps its own copy so they can
# version/update independently.
#
# Usage: source this file, then call er_pipewire_slots_available.

er_pipewire_slots_available() {
    local code
    code="$(curl -s -m 3 -o /dev/null -w '%{http_code}' \
        "http://localhost/api/command/Media%20Slot%20Status" 2>/dev/null || echo 000)"
    [[ "$code" == "200" ]]
}
