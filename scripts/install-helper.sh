#!/bin/bash
# Install ChargeKitHelper as a root LaunchDaemon. Run with sudo.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/../Package.swift" ]; then
    REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
    SOURCE_BIN="${CHARGEKIT_SOURCE_BIN:-$REPO/.build/release/ChargeKitHelper}"
    APP_PATH="${CHARGEKIT_APP_PATH:-$REPO/build/ChargeKit.app}"
else
    # Installed copy inside ChargeKit.app/Contents/Resources.
    APP_PATH="${CHARGEKIT_APP_PATH:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
    SOURCE_BIN="${CHARGEKIT_SOURCE_BIN:-$APP_PATH/Contents/Library/LaunchServices/ChargeKitHelper}"
fi
APP_VERSION="${CHARGEKIT_APP_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo unknown)}"
DEST="/Library/PrivilegedHelperTools/com.chargekit.helper"
PLIST="/Library/LaunchDaemons/com.chargekit.helper.plist"
RECOVERY_MARKER="/var/db/com.chargekit.helper.adapter-recovery"
SERVICE="system/com.chargekit.helper"

[ -x "$SOURCE_BIN" ] || { echo "helper binary missing: $SOURCE_BIN"; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
[ ! -e "$RECOVERY_MARKER" ] || { echo "wait for adapter recovery before upgrading"; exit 1; }
/usr/bin/codesign --verify -- "$APP_PATH"
CLIENT_HASH="$(/usr/bin/codesign -d --verbose=4 -- "$APP_PATH" 2>&1 | /usr/bin/sed -n 's/^CDHash=//p')"
[[ "$CLIENT_HASH" =~ ^[0-9a-f]{40}$ ]] || { echo "app signing hash unavailable"; exit 1; }
escape_xml() {
    /usr/bin/sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}
APP_PATH_XML="$(printf '%s' "$APP_PATH" | escape_xml)"
APP_VERSION_XML="$(printf '%s' "$APP_VERSION" | escape_xml)"

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
    launchctl bootstrap system "$PLIST"
    echo "wait for adapter recovery before upgrading"
    exit 1
fi

install -m 0755 "$SOURCE_BIN" "$DEST"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>EnvironmentVariables</key>
    <dict>
        <key>CHARGEKIT_APP_PATH</key>
        <string>$APP_PATH_XML</string>
        <key>CHARGEKIT_APP_VERSION</key>
        <string>$APP_VERSION_XML</string>
        <key>CHARGEKIT_CLIENT_CDHASH</key>
        <string>$CLIENT_HASH</string>
    </dict>
    <key>Label</key>
    <string>com.chargekit.helper</string>
    <key>Program</key>
    <string>$DEST</string>
    <key>MachServices</key>
    <dict>
        <key>com.chargekit.helper</key>
        <true/>
    </dict>
    <key>KeepAlive</key>
    <dict>
        <key>PathState</key>
        <dict>
            <key>$RECOVERY_MARKER</key>
            <true/>
        </dict>
    </dict>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
EOF

# The daemon's SIGTERM exit path does synchronous SMC writes, so a
# just-booted-out job may still be settling; retry with growing delays
# (seen in the wild as "Bootstrap failed: 5: Input/output error", once
# surviving even the 2 s retry).
launchctl bootstrap system "$PLIST" || {
    sleep 2
    launchctl bootstrap system "$PLIST" || {
        sleep 5
        launchctl bootstrap system "$PLIST"
    }
}
launchctl enable system/com.chargekit.helper
echo "ChargeKitHelper registered for on-demand use:"
launchctl print system/com.chargekit.helper | grep -E 'state|pid' | head -3
