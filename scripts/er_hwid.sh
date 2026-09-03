#!/usr/bin/env bash
# Encore Radio - hardware fingerprint for trial-hour tracking.
#
# Prints a stable identifier for this Pi that survives an Encore Radio
# uninstall/reinstall (unlike a locally-generated UUID, which would reset
# on reinstall) - the whole point being that reinstalling the plugin can't
# be used to get a fresh trial. Prefers the CPU serial (immutable per
# board, survives an SD card reflash too); falls back to /etc/machine-id
# if unavailable (e.g. testing in a non-Pi environment), which is weaker
# (a reflash regenerates it) but still resists a plain plugin reinstall.

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
