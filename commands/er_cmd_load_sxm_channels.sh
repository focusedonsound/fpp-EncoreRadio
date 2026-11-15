#!/bin/bash
# FPP Command: Encore Radio - Load SiriusXM Channels
#
# Internal - dispatched by the plugin page's "Connect & load channels" button
# (www/sxm_load_channels.php) so the channel-lineup fetch runs in root context
# via fppd, the same way Start/Stop do. Not meant to be run manually or from a
# Schedule. Delegates to the real worker in scripts/.

set -uo pipefail

PLUGIN_DIR="$(dirname "$(dirname "$0")")"
exec bash "${PLUGIN_DIR}/scripts/er_load_sxm_channels.sh"
