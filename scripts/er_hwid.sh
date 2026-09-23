#!/usr/bin/env bash
# Encore Radio - hardware fingerprint for paid-license binding.
#
# Prints a stable identifier for this Pi. Trial-hour tracking is entirely
# local and never uses this (see er_track_usage.sh/er_premium_gate.sh) -
# this is only ever sent for validate_license_key() (er_premium_gate.sh),
# to bind a paid license key to the device it was first validated on.
# Prefers the CPU serial (immutable per board, survives an SD card
# reflash too); falls back to /etc/machine-id if unavailable (e.g.
# testing in a non-Pi environment), which is weaker (a reflash
# regenerates it) but still identifies the device across a plain plugin
# reinstall.

set -uo pipefail

serial="$(awk -F': ' '/^Serial/ {print $2}' /proc/cpuinfo 2>/dev/null | tr -d '\n')"

if [[ -n "$serial" && "$serial" != "0000000000000000" ]]; then
    echo "cpu-${serial}"
    exit 0
fi

if [[ -f /etc/machine-id ]]; then
    echo "machine-$(cat /etc/machine-id)"
    exit 0
fi

echo "unknown"
exit 1
