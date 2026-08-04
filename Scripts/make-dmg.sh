#!/bin/bash
#
# Builds the distributable disk image.
#
# A DMG rather than a .pkg for two reasons: signing a package needs a "Developer ID
# Installer" certificate, which is a different cert from the "Developer ID
# Application" one used for the app; and the drag-to-Applications gesture is the
# thing that gets this app into /Applications, which it *must* be in — launchd only
# resolves the bundled helper daemon for apps installed there.
#
# Usage: Scripts/make-dmg.sh
#
# Produces dist/MacUninstall.dmg, signed with the same identity as the app. Run
# Scripts/notarize.sh afterwards to submit and staple it.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="MacUninstall"
VOLUME_NAME="Mac Uninstall"
BUILD_ROOT="${MACUNINSTALL_BUILD_DIR:-$ROOT/dist}"
APP="$BUILD_ROOT/$APP_NAME.app"
DMG="$BUILD_ROOT/$APP_NAME.dmg"

if [ ! -d "$APP" ]; then
    echo "==> No app at $APP; building it first"
    "$ROOT/Scripts/build-app.sh" release
fi

# ------------------------------------------------------------------ stage ----

echo "==> Staging"
STAGE="$(mktemp -d)/$VOLUME_NAME"
mkdir -p "$STAGE"
trap 'rm -rf "$(dirname "$STAGE")"; hdiutil detach "/Volumes/$VOLUME_NAME" -quiet 2>/dev/null || true' EXIT

ditto "$APP" "$STAGE/$APP_NAME.app"
# The symlink is the install step: drag the app onto it.
ln -s /Applications "$STAGE/Applications"

# ------------------------------------------------------------------ build ----

# Built read-write first so the Finder window can be arranged, then compressed.
RW_DMG="$(dirname "$STAGE")/rw.dmg"
echo "==> Creating image"
hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGE" -ov \
    -format UDRW -fs HFS+ "$RW_DMG" | sed 's/^/    /'

echo "==> Arranging the window"
hdiutil attach "$RW_DMG" -noautoopen -quiet
# Best effort: the layout needs Finder, which may be unavailable or unapproved on a
# build machine. A DMG without icon positions still installs perfectly well, so a
# failure here must not fail the build.
osascript <<APPLESCRIPT 2>/dev/null || echo "    (skipped: Finder could not be scripted)"
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 140, 780, 480}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 128
        set position of item "$APP_NAME.app" of container window to {150, 170}
        set position of item "Applications" of container window to {430, 170}
        close
        open
        update without registering applications
        delay 1
    end tell
end tell
APPLESCRIPT

sync
hdiutil detach "/Volumes/$VOLUME_NAME" -quiet || true

echo "==> Compressing"
rm -f "$DMG"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" | sed 's/^/    /'

# ------------------------------------------------------------------- sign ----

# The DMG is signed with the app's identity. Gatekeeper checks the image itself, so
# an unsigned container around a signed app still warns on first open.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')

if [ -n "$IDENTITY" ]; then
    echo "==> Signing with: $IDENTITY"
    codesign --force --timestamp --sign "$IDENTITY" "$DMG" 2>&1 | sed 's/^/    /'
    codesign --verify --verbose=2 "$DMG" 2>&1 | sed 's/^/    /'
else
    echo "==> No Developer ID Application certificate; leaving the image unsigned"
fi

echo "==> Verifying the image"
hdiutil verify "$DMG" 2>&1 | tail -2 | sed 's/^/    /'

SIZE=$(du -h "$DMG" | cut -f1 | tr -d ' ')
echo
echo "Built $DMG ($SIZE)"
echo
echo "Not yet notarised — Gatekeeper will warn on other Macs until it is."
echo "Store credentials once, then notarise:"
echo
echo "    xcrun notarytool store-credentials MacUninstall \\"
echo "        --apple-id \"you@example.com\" --team-id F57J2WBYN8"
echo "    Scripts/notarize.sh"
