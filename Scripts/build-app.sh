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
# The public half of the Sparkle signing key. Safe to commit — it only lets a copy of
# the app verify that an update came from the holder of the private key. Regenerate
# both halves with Scripts/../.build/artifacts/sparkle/Sparkle/bin/generate_keys.
SPARKLE_PUBLIC_KEY="19ffzcCYWRMyrDlBEsF4yTaCd/qmvvgYiQu/1QwD7Do="
# Where the app looks for updates. Overridable so the whole update path can be
# rehearsed against a local feed before a release goes out — see README.
SPARKLE_FEED_URL="${MACUNINSTALL_FEED_URL:-https://github.com/matthewazevedo/mac-uninstall/releases/latest/download/appcast.xml}"
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

# Both versions come from the git tag, because the tag is what the release workflow
# ships and what the appcast advertises. Sparkle decides whether an update is newer by
# comparing CFBundleVersion, so it has to be a plain dotted number that sorts
# correctly — `git describe` output like "v0.1.0-3-gb7d101f" does not compare at all.
#
# Override with MACUNINSTALL_VERSION to build a specific version without tagging.
if [ -n "${MACUNINSTALL_VERSION:-}" ]; then
    SHORT_VERSION="${MACUNINSTALL_VERSION#v}"
    VERSION="$SHORT_VERSION"
else
    TAG="$(git -C "$ROOT" describe --tags --abbrev=0 --match 'v*' 2>/dev/null || echo "v0.0.0")"
    SHORT_VERSION="${TAG#v}"
    COMMITS_SINCE="$(git -C "$ROOT" rev-list "$TAG..HEAD" --count 2>/dev/null || echo 0)"
    if [ "$COMMITS_SINCE" = "0" ]; then
        VERSION="$SHORT_VERSION"
    else
        # A build ahead of the last tag must never compare equal to the release it
        # came from, or Sparkle would treat a released update as "already installed".
        # 0.1.0.3 sorts above 0.1.0 and below 0.1.1.
        VERSION="$SHORT_VERSION.$COMMITS_SINCE"
    fi
fi

echo "==> Version $SHORT_VERSION (build $VERSION)"

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$BUILD_ROOT"
mkdir -p "$APP/Contents/MacOS" \
         "$APP/Contents/Resources" \
         "$APP/Contents/Frameworks" \
         "$APP/Contents/Library/LaunchDaemons"

cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$BIN_DIR/$HELPER_ID" "$APP/Contents/MacOS/$HELPER_ID"

# ------------------------------------------------------------------ sparkle ----

# SwiftPM leaves Sparkle.framework beside the binaries but has no notion of an app
# bundle, so embedding it is this script's job. -a preserves the version symlinks a
# framework needs; a flat copy will not load.
echo "==> Embedding Sparkle"
cp -a "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/"

# The executable is linked against @rpath/Sparkle.framework with only @loader_path on
# its run-path list, which resolves to Contents/MacOS. The framework lives one level
# up in Contents/Frameworks, so without this the app dies at launch with "Library not
# loaded". Harmless if a future SwiftPM starts adding it, hence the || true.
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true

echo "==> Drawing the app icon"
# Generated rather than checked in, so the icon stays in step with the design
# system's size ladder rather than drifting from it as a stale binary.
ICONSET="$(mktemp -d)/AppIcon.iconset"
swift "$ROOT/Scripts/make-icon.swift" "$ICONSET" | sed 's/^/    /'
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

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
    <key>CFBundleIconFile</key>              <string>AppIcon</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Mac Uninstall needs administrator rights to move system-level leftovers, such as launch daemons and privileged helper tools, out of the way.</string>
    <key>NSSystemAdministrationUsageDescription</key>
    <string>Mac Uninstall removes files that applications leave behind in system folders.</string>

    <!-- Updates. The feed is a release asset rather than a file in the repository or
         a Pages site: GitHub resolves /releases/latest/download/<name> to the newest
         release's asset of that name, so the URL is stable while each release
         publishes its own appcast. Nothing extra to host, nothing to keep in sync. -->
    <key>SUFeedURL</key>
    <string>$SPARKLE_FEED_URL</string>
    <!-- Updates are only trusted if signed by the matching private key, which lives
         in the maintainer's keychain and in one CI secret. A compromised feed alone
         cannot ship code: the signature is checked before anything is unpacked. -->
    <key>SUPublicEDKey</key>
    <string>$SPARKLE_PUBLIC_KEY</string>
    <!-- Check on a schedule, but never install on its own. An app whose whole point
         is that it deletes nothing without showing you first should not replace
         itself without asking either. -->
    <key>SUEnableAutomaticChecks</key>              <true/>
    <key>SUAutomaticallyUpdate</key>                <false/>
    <key>SUScheduledCheckInterval</key>             <integer>86400</integer>
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

# Sparkle ships its own nested code — two XPC services, the updater UI, and the
# installer that runs after the app quits — each pre-signed by the Sparkle project.
# Notarisation rejects anything inside the bundle that is not signed by us, so every
# piece is re-signed here, innermost first. None of it gets the app's entitlements:
# these are separate programs, and the Apple Events entitlement is the app's alone.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"

echo "==> Signing Sparkle"
for NESTED in \
    "$SPARKLE/XPCServices/Downloader.xpc" \
    "$SPARKLE/XPCServices/Installer.xpc" \
    "$SPARKLE/Updater.app" \
    "$SPARKLE/Autoupdate"
do
    codesign --force --options runtime --timestamp \
        --sign "$IDENTITY" "$NESTED" 2>&1 | sed 's/^/    /'
done

# The framework itself is sealed last, so it covers the nested code just re-signed.
codesign --force --options runtime --timestamp \
    --sign "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework" 2>&1 | sed 's/^/    /'

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
