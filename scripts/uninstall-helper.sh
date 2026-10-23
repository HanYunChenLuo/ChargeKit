#!/bin/bash
# Remove ChargeKitHelper LaunchDaemon (restores the adapter first).
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

# Graceful stop: SIGTERM triggers the helper's adapter-restore handler.
launchctl bootout system/com.chargekit.helper 2>/dev/null || true
rm -f /Library/LaunchDaemons/com.chargekit.helper.plist
rm -f /Library/PrivilegedHelperTools/com.chargekit.helper
echo "ChargeKitHelper removed"
