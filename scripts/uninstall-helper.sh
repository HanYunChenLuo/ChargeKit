#!/bin/bash
# Remove ChargeKitHelper LaunchDaemon (restores the adapter first).
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
RECOVERY_MARKER="/var/db/com.chargekit.helper.adapter-recovery"
SERVICE="system/com.chargekit.helper"
[ ! -e "$RECOVERY_MARKER" ] || { echo "wait for adapter recovery before uninstalling"; exit 1; }

# Confirm launchd removed the job and the old daemon completed its exit.
if old_job="$(LC_ALL=C launchctl print "$SERVICE" 2>&1)"; then
    old_pid="$(printf '%s\n' "$old_job" | awk '$1 == "pid" && $2 == "=" { print $3; exit }')"
    launchctl bootout "$SERVICE"
    for ((attempt = 0; attempt < 20; attempt++)); do
        if [[ -z "$old_pid" ]] || ! kill -0 "$old_pid" 2>/dev/null; then break; fi
        sleep 0.25
    done
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
        echo "old helper is still stopping" >&2
        exit 1
    fi
elif [[ "$old_job" != *'Could not find service "com.chargekit.helper"'* ]]; then
    printf '%s\n' "$old_job" >&2
    exit 1
fi
if job_status="$(LC_ALL=C launchctl print "$SERVICE" 2>&1)" ||
    [[ "$job_status" != *'Could not find service "com.chargekit.helper"'* ]]; then
    printf 'cannot confirm helper stopped\n%s\n' "$job_status" >&2
    exit 1
fi
if [ -e "$RECOVERY_MARKER" ]; then
    launchctl bootstrap system /Library/LaunchDaemons/com.chargekit.helper.plist
    echo "wait for adapter recovery before uninstalling"
    exit 1
fi
rm -f /Library/LaunchDaemons/com.chargekit.helper.plist
rm -f /Library/PrivilegedHelperTools/com.chargekit.helper
echo "ChargeKitHelper removed"
