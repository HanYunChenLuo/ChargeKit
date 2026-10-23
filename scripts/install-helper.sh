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

[ -x "$SOURCE_BIN" ] || { echo "helper binary missing: $SOURCE_BIN"; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

# Out with the old
launchctl bootout system/com.chargekit.helper 2>/dev/null || true

install -m 0755 "$SOURCE_BIN" "$DEST"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>EnvironmentVariables</key>
    <dict>
        <key>CHARGEKIT_APP_PATH</key>
        <string>$APP_PATH</string>
        <key>CHARGEKIT_APP_VERSION</key>
        <string>$APP_VERSION</string>
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
echo "ChargeKitHelper installed and running:"
launchctl print system/com.chargekit.helper | grep -E 'state|pid' | head -3
