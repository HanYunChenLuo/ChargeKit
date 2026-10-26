#!/bin/bash
# Assemble ChargeKit.app from SPM release build.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="$REPO/build/ChargeKit.app"
BIN="$REPO/.build/release/ChargeKitApp"

[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchServices"

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
    <string>0.5.0</string>
    <key>CFBundleVersion</key>
    <string>6</string>
    <key>SUFeedURL</key>
    <string>https://github.com/HanYunChenLuo/ChargeKit/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>MUS+AOtobGIonWlNPzu9eoUVL9VbfekRRARYmJ9o394=</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

cp "$BIN" "$APP/Contents/MacOS/ChargeKitApp"

# Sparkle auto-update framework: linked via @rpath, so embed it in
# Frameworks/ and point the executable at that copy.
SPARKLE_FW="$REPO/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[ -d "$SPARKLE_FW" ] || { echo "run swift build first (Sparkle dependency missing)"; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/ChargeKitApp"

# Helper payload: embedded in the app bundle so the app can install or
# refresh the LaunchDaemon from its own resources.
HELPER_BIN="$REPO/.build/release/ChargeKitHelper"
[ -x "$HELPER_BIN" ] || { echo "build first: swift build -c release"; exit 1; }
cp "$HELPER_BIN" "$APP/Contents/Library/LaunchServices/ChargeKitHelper"
cp "$REPO/scripts/install-helper.sh" "$APP/Contents/Resources/install-helper.sh"

# App icon (single dual-mode-friendly icon; see make-icon.sh for the
# appearance-variant constraint).
cp "$REPO/scripts/ChargeKit.icns" "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"
echo "Assembled $APP"
