#!/bin/bash
#
# Notarises MacUninstall.app and produces a stapled, distributable DMG.
#
# Prerequisite — store your credentials once, interactively:
#
#   xcrun notarytool store-credentials MacUninstall \
#       --apple-id "you@example.com" --team-id F57J2WBYN8
#
# It will prompt for an app-specific password, generated at appleid.apple.com.
# Run that yourself; this script never handles credentials, it only names the
# stored profile.
#
# Usage: Scripts/notarize.sh [profile-name]

set -euo pipefail

PROFILE="${1:-MacUninstall}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="MacUninstall"
BUILD_ROOT="${MACUNINSTALL_BUILD_DIR:-$HOME/Library/Caches/MacUninstall/build}"
APP="$BUILD_ROOT/$APP_NAME.app"
DIST="$ROOT/dist"
DMG="$BUILD_ROOT/$APP_NAME.dmg"

if [ ! -d "$APP" ]; then
    echo "No staged build found at $APP"
    echo "Run Scripts/build-app.sh release first."
    exit 1
fi

# ------------------------------------------------------------- preflight -----

echo "==> Checking the signature"
IDENTITY_LINE="$(codesign --display --verbose=2 "$APP" 2>&1 | grep '^Authority=' | head -1)"
echo "    $IDENTITY_LINE"

if ! echo "$IDENTITY_LINE" | grep -q "Developer ID Application"; then
    cat <<'NOTE'

Notarisation requires a "Developer ID Application" signature. This build is signed
with something else, so it would be rejected. Rebuild with:

    Scripts/build-app.sh release

NOTE
    exit 1
fi

# Hardened runtime is mandatory for notarisation; catch it here rather than after
# a round trip to Apple.
if ! codesign --display --verbose=2 "$APP" 2>&1 | grep -q "flags=.*runtime"; then
    echo "The hardened runtime is not enabled. Rebuild with Scripts/build-app.sh."
    exit 1
fi

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    cat <<NOTE

No stored notarytool credentials named "$PROFILE".

Create them once, in your own terminal:

    xcrun notarytool store-credentials $PROFILE \\
        --apple-id "you@example.com" --team-id F57J2WBYN8

NOTE
    exit 1
fi

# ------------------------------------------------------------------ dmg ------

echo "==> Building DMG"
rm -f "$DMG"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" \
    | sed 's/^/    /'

# --------------------------------------------------------------- notarise ----

echo "==> Submitting to Apple (this usually takes a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait \
    | sed 's/^/    /'

echo "==> Stapling"
# Staple the DMG and the app inside it, so both work offline.
xcrun stapler staple "$DMG" | sed 's/^/    /'
xcrun stapler staple "$APP" | sed 's/^/    /'

echo "==> Verifying Gatekeeper acceptance"
spctl --assess --type execute --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

mkdir -p "$DIST"
cp "$DMG" "$DIST/$APP_NAME.dmg"

echo
echo "Notarised and stapled."
echo "  $DIST/$APP_NAME.dmg"
