#!/bin/bash
# FPP Command: Encore Radio - Stop

set -euo pipefail

PLUGIN_DIR="$(dirname "$(dirname "$0")")"
exec bash "${PLUGIN_DIR}/scripts/er_stop.sh"
