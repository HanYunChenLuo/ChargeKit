#!/bin/bash
# Assemble ChargeKit.app from SPM release build.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="$REPO/build/ChargeKit.app"
BIN="$REPO/.build/release/ChargeKitApp"

[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ChargeKitApp</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.chargekit.app</string>
    <key>CFBundleName</key>
    <string>ChargeKit</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.3.0</string>
    <key>CFBundleVersion</key>
    <string>4</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

cp "$BIN" "$APP/Contents/MacOS/ChargeKitApp"

# App icon (single dual-mode-friendly icon; see make-icon.sh for the
# appearance-variant constraint).
cp "$REPO/scripts/ChargeKit.icns" "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"
echo "Assembled $APP"
