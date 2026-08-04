#!/bin/bash
#
# Builds MacUninstall.app, embedding the privileged helper daemon.
#
# The helper is installed by SMAppService from inside the app bundle, so there is no
# separate installer and no setuid binary. That requires an exact layout:
#
#   MacUninstall.app/Contents/MacOS/MacUninstall
#   MacUninstall.app/Contents/MacOS/com.macuninstall.helper
#   MacUninstall.app/Contents/Library/LaunchDaemons/com.macuninstall.helper.plist
#
# Signing runs inside-out — helper first, then the app — because signing the outer
# bundle seals whatever the inner contents are at that moment.
#
# Usage: Scripts/build-app.sh [debug|release]
#
# Environment:
#   MACUNINSTALL_SIGN_IDENTITY  Override the signing identity. Otherwise a
#                               "Developer ID Application" certificate is preferred,
#                               then "Apple Development", then ad-hoc.

set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ID="com.macuninstall.app"
HELPER_ID="com.macuninstall.helper"
APP_NAME="MacUninstall"
# Keep the repository off any file-syncing service. A provider such as iCloud Drive
# re-attaches a com.apple.FinderInfo xattr within seconds of each write, and codesign
# refuses to seal a bundle carrying one — so a build inside a synced folder fails
# strict verification no matter how often the xattr is stripped.
BUILD_ROOT="${MACUNINSTALL_BUILD_DIR:-$ROOT/dist}"
DIST="$BUILD_ROOT"
APP="$BUILD_ROOT/$APP_NAME.app"

# ---------------------------------------------------------------- identity ----

pick_identity() {
    if [ -n "${MACUNINSTALL_SIGN_IDENTITY:-}" ]; then
        echo "$MACUNINSTALL_SIGN_IDENTITY"; return
    fi
    local found
    # Developer ID Application is the only cert type Gatekeeper accepts for direct
    # distribution. Apple Distribution is for the App Store and will not notarise.
    found=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')
    if [ -n "$found" ]; then echo "$found"; return; fi
    found=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep "Apple Development" | head -1 | sed -E 's/.*"(.*)"/\1/')
    if [ -n "$found" ]; then echo "$found"; return; fi
    echo "-"
}

IDENTITY="$(pick_identity)"
TEAM_ID="$(echo "$IDENTITY" | sed -nE 's/.*\(([A-Z0-9]{10})\)$/\1/p')"

case "$IDENTITY" in
    "-")                          IDENTITY_KIND="ad-hoc" ;;
    "Developer ID Application"*)  IDENTITY_KIND="developer-id" ;;
    *)                            IDENTITY_KIND="development" ;;
esac

echo "==> Signing identity: $IDENTITY  [$IDENTITY_KIND]"

# ------------------------------------------------------------------- build ----

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG" --package-path "$ROOT" --product "$APP_NAME"
swift build -c "$CONFIG" --package-path "$ROOT" --product "$HELPER_ID"
BIN_DIR="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)"

VERSION="$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo "0.1.0")"
SHORT_VERSION="0.1.0"

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$BUILD_ROOT"
mkdir -p "$APP/Contents/MacOS" \
         "$APP/Contents/Resources" \
         "$APP/Contents/Library/LaunchDaemons"

cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$BIN_DIR/$HELPER_ID" "$APP/Contents/MacOS/$HELPER_ID"

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
    <key>CFBundleShortVersionString</key>    <string>$SHORT_VERSION</string>
    <key>CFBundleVersion</key>               <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>        <string>14.0</string>
    <key>NSHighResolutionCapable</key>       <true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSPrincipalClass</key>              <string>NSApplication</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Mac Uninstall needs administrator rights to move system-level leftovers, such as launch daemons and privileged helper tools, out of the way.</string>
    <key>NSSystemAdministrationUsageDescription</key>
    <string>Mac Uninstall removes files that applications leave behind in system folders.</string>
</dict>
</plist>
PLIST

# The daemon's launchd job. AssociatedBundleIdentifiers is what makes this appear
# under the app's own name in System Settings > Login Items rather than as an
# anonymous background item.
cat > "$APP/Contents/Library/LaunchDaemons/$HELPER_ID.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>          <string>$HELPER_ID</string>
    <key>BundleProgram</key>  <string>Contents/MacOS/$HELPER_ID</string>
    <key>MachServices</key>
    <dict>
        <key>$HELPER_ID</key> <true/>
    </dict>
    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>$BUNDLE_ID</string>
    </array>
</dict>
</plist>
PLIST

# ------------------------------------------------------------ entitlements ----

ENTITLEMENTS_DIR="$(mktemp -d)"
trap 'rm -rf "$ENTITLEMENTS_DIR"' EXIT

# The app is deliberately not sandboxed: a sandboxed process cannot read other apps'
# Library folders, which is the entire job. Apple Events access is needed for the
# authenticated fallback path when the helper is not yet approved.
cat > "$ENTITLEMENTS_DIR/app.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>              <false/>
    <key>com.apple.security.automation.apple-events</key>  <true/>
</dict>
</plist>
PLIST

# The helper needs nothing. It runs as root; every additional entitlement is a
# larger target, so it gets none.
cat > "$ENTITLEMENTS_DIR/helper.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key> <false/>
</dict>
</plist>
PLIST

# ------------------------------------------------------------------- sign -----

# Copying through the filesystem can attach quarantine and Finder metadata, which
# codesign refuses to seal. Strip it before signing rather than after.
xattr -cr "$APP"

echo "==> Signing helper"
codesign --force --options runtime --timestamp \
    --identifier "$HELPER_ID" \
    --entitlements "$ENTITLEMENTS_DIR/helper.entitlements" \
    --sign "$IDENTITY" "$APP/Contents/MacOS/$HELPER_ID" 2>&1 | sed 's/^/    /'

echo "==> Signing app"
codesign --force --options runtime --timestamp \
    --identifier "$BUNDLE_ID" \
    --entitlements "$ENTITLEMENTS_DIR/app.entitlements" \
    --sign "$IDENTITY" "$APP" 2>&1 | sed 's/^/    /'

echo "==> Verifying"
codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'
codesign --verify --strict --verbose=2 "$APP/Contents/MacOS/$HELPER_ID" 2>&1 | sed 's/^/    /'
# Confirm the helper is sealed into the app, not merely sitting beside it.
codesign --display --verbose=4 "$APP" 2>&1 | grep -q "Sealed Resources" \
    || echo "    warning: no sealed resources reported"

echo
echo "Built $APP"
echo "Team: ${TEAM_ID:-none}"
echo

case "$IDENTITY_KIND" in
    developer-id)
        echo "Ready to notarise:  Scripts/notarize.sh"
        ;;
    development)
        cat <<'NOTE'
Signed with an Apple Development certificate. This runs locally, but it cannot be
notarised or distributed — Gatekeeper will reject it on other Macs. Create a
"Developer ID Application" certificate (Xcode > Settings > Accounts > Manage
Certificates > + > Developer ID Application) and rebuild to get a distributable app.
NOTE
        ;;
    ad-hoc)
        cat <<'NOTE'
Signed ad-hoc. The privileged helper will fall back to an identifier-only client
check, which is for local development only, and Full Disk Access must be re-granted
after every rebuild because the signing identity changes.
NOTE
        ;;
esac

echo
echo "Run it with:  open \"$APP\""
