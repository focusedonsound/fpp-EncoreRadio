#!/bin/bash
# FPP Command: Encore Radio - Sync Spotify Service

set -euo pipefail

PLUGIN_DIR="$(dirname "$(dirname "$0")")"
exec bash "${PLUGIN_DIR}/scripts/er_sync_spotify_service.sh"
