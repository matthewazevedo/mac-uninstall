#!/bin/bash
#
# Builds MacUninstall.app from the SwiftPM executable.
#
# SwiftPM produces a bare Mach-O binary, but a SwiftUI app needs a real bundle to
# get a Dock icon, a menu bar, and its own TCC identity — Full Disk Access is granted
# per code-signing identity, so the app must be signed and stable across rebuilds.
#
# Usage: Scripts/build-app.sh [debug|release]

set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ID="com.macuninstall.app"
APP_NAME="MacUninstall"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG" --package-path "$ROOT"
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/$APP_NAME"

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

VERSION="$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo "0.1.0")"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>           <string>Mac Uninstall</string>
    <key>CFBundleExecutable</key>            <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>            <string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleShortVersionString</key>    <string>0.1.0</string>
    <key>CFBundleVersion</key>               <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>        <string>14.0</string>
    <key>NSHighResolutionCapable</key>       <true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSPrincipalClass</key>              <string>NSApplication</string>
    <!-- Shown when the app requests administrator rights to move system files. -->
    <key>NSAppleEventsUsageDescription</key>
    <string>Mac Uninstall needs administrator rights to move system-level leftovers, such as launch daemons and privileged helper tools, out of the way.</string>
    <key>NSSystemAdministrationUsageDescription</key>
    <string>Mac Uninstall removes files that applications leave behind in system folders.</string>
</dict>
</plist>
PLIST

echo "==> Signing"
# Full Disk Access is bound to the signing identity. Set MACUNINSTALL_SIGN_IDENTITY
# to a Developer ID to produce a build you can notarise and distribute; the ad-hoc
# fallback is fine locally but the permission must be re-granted whenever it changes.
IDENTITY="${MACUNINSTALL_SIGN_IDENTITY:--}"
codesign --force --deep --options runtime --sign "$IDENTITY" "$APP" 2>&1 | sed 's/^/    /'

echo "==> Verifying"
codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

echo
echo "Built $APP"
echo
if [ "$IDENTITY" = "-" ]; then
    echo "Signed ad-hoc. Grant Full Disk Access in System Settings > Privacy & Security,"
    echo "otherwise protected folders read as empty and leftovers will be missed."
fi
echo "Run it with:  open \"$APP\""
