#!/bin/bash
# Builds TajArchive (Release) and installs it into /Applications on THIS Mac.
#
# For shipping to other people use Scripts/release.sh instead — it produces a
# signed, notarized DMG.
#
# Two rules this script keeps:
#  * It never re-signs anything. Xcode's signature, with the correct
#    entitlements, stands as-is (an old ad-hoc "codesign --deep" re-sign used to
#    strip the extensions' sandbox entitlement and break them).
#  * It leaves exactly ONE registered copy of the app on the system. Every .app
#    Xcode builds is registered with Launch Services, and macOS then picks the
#    Finder / Quick Look extension from whichever copy it likes — often a stale
#    one in a build folder. So the build happens in a temp folder that is
#    unregistered and deleted once /Applications holds the result.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$ROOT/7-Zip/7-Zip.xcodeproj"
SCHEME="7-Zip"
APP_NAME="TajArchive.app"
DEST="/Applications/$APP_NAME"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tajarchive-deploy.XXXXXX")"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

cleanup() {
    # Forget the temporary build products so macOS never prefers them
    if [ -d "$BUILD_DIR/Build/Products/Release/$APP_NAME" ]; then
        for ext in "$BUILD_DIR/Build/Products/Release/$APP_NAME"/Contents/PlugIns/*.appex; do
            [ -d "$ext" ] && pluginkit -r "$ext" 2>/dev/null || true
        done
        "$LSREGISTER" -u "$BUILD_DIR/Build/Products/Release/$APP_NAME" 2>/dev/null || true
    fi
    rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

echo "=== 1/5 Building (Release) ==="
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    build -quiet

APP_SRC="$BUILD_DIR/Build/Products/Release/$APP_NAME"
[ -d "$APP_SRC" ] || { echo "ERROR: build succeeded but $APP_SRC was not found." >&2; exit 1; }

echo "=== 2/5 Replacing the installed copy ==="
# Quit a running copy first, or macOS keeps the old binary mapped
osascript -e 'tell application "TajArchive" to quit' >/dev/null 2>&1 || true
sleep 1

# The app used to be called 7-Zip.app (bundle id com.donishsoft.7zip). Leaving it
# installed means two Finder menus and two competing Quick Look extensions.
LEGACY="/Applications/7-Zip.app"
if [ -d "$LEGACY" ] && [ "$(defaults read "$LEGACY/Contents/Info" CFBundleIdentifier 2>/dev/null)" = "com.donishsoft.7zip" ]; then
    for ext in "$LEGACY"/Contents/PlugIns/*.appex; do pluginkit -r "$ext" 2>/dev/null || true; done
    "$LSREGISTER" -u "$LEGACY" 2>/dev/null || true
    mv "$LEGACY" "$HOME/.Trash/7-Zip-legacy-$(date +%Y%m%d%H%M%S).app"
    echo "    Moved the old 7-Zip.app (previous name of this app) to the Trash"
fi

rm -rf "$DEST"
ditto "$APP_SRC" "$DEST"
echo "    Installed $DEST"

echo "=== 3/5 Registering the installed copy ==="
"$LSREGISTER" -f "$DEST"
for ext in "$DEST"/Contents/PlugIns/*.appex; do
    pluginkit -a "$ext" 2>/dev/null || true
done

echo "=== 4/5 Refreshing Quick Look ==="
qlmanage -r >/dev/null 2>&1 || true
qlmanage -r cache >/dev/null 2>&1 || true

echo "=== 5/5 Finder extension ==="
STATE="$(pluginkit -m -i com.donishsoft.tajarchive.FinderExtension 2>/dev/null | cut -c1)"
if [ "$STATE" = "+" ]; then
    echo "    Enabled — right-click any file in Finder for the TajArchive menu."
else
    echo "    Not enabled yet. Launch TajArchive once: it offers to switch the"
    echo "    Finder menu on with a single click."
fi

echo ""
echo "Deploy complete: $DEST"
