#!/bin/bash
# Release pipeline for TajArchive.
#
#   archive → Developer ID export → notarize + staple the app → disk image with the
#   drag-to-Applications layout → sign → notarize + staple the image → Gatekeeper check
#
# Output: build/release/ (DMG, the 7-Zip source tarball the LGPL asks for, SHA-256 sums),
# plus a copy of the DMG on the Desktop.
#
# Notarization needs a keychain profile, created once. Run this script in Terminal and it
# offers to create it: you are asked for an app-specific password made at
# https://appleid.apple.com → Sign-In and Security → App-Specific Passwords.
# By hand:
#   xcrun notarytool store-credentials TAJARCHIVE_NOTARY --apple-id <Apple ID> --team-id B65SR885N5
#
# Environment overrides: APPLE_ID, TEAM_ID, NOTARY_PROFILE, SKIP_NOTARIZE=1 (test builds).

set -euo pipefail

die() {
    echo "" >&2
    echo "ERROR: $1" >&2
    exit 1
}
step() { echo ""; echo "=== $1 ==="; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PROJECT="7-Zip/7-Zip.xcodeproj"
SCHEME="7-Zip"
TEAM_ID="${TEAM_ID:-B65SR885N5}"
APPLE_ID="${APPLE_ID:-info@donishsoft.com}"
NOTARY_PROFILE="${NOTARY_PROFILE:-TAJARCHIVE_NOTARY}"
BUILD_DIR="$ROOT/build"
RELEASE_DIR="$BUILD_DIR/release"
# ".noindex" keeps Spotlight out: it would otherwise register the intermediate app with
# Launch Services, and macOS could then take the Finder menu from that copy.
WORK_DIR="$BUILD_DIR/work.noindex"
ARCHIVE_PATH="$WORK_DIR/TajArchive.xcarchive"
EXPORT_DIR="$WORK_DIR/export"
EXPORT_PLIST="$WORK_DIR/ExportOptions.plist"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

[ -d "$PROJECT" ] || die "Xcode project not found at $ROOT/$PROJECT"

# Build products must never become the copy macOS uses for the Finder menu or Quick
# Look, so every bundle this script produces is unregistered again on exit.
forget_bundle() {
    local app="$1"
    [ -d "$app" ] || return 0
    for appex in "$app"/Contents/PlugIns/*.appex; do
        [ -d "$appex" ] && pluginkit -r "$appex" 2>/dev/null || true
    done
    "$LSREGISTER" -u "$app" 2>/dev/null || true
}
cleanup() {
    forget_bundle "$ARCHIVE_PATH/Products/Applications/TajArchive.app"
    forget_bundle "$EXPORT_DIR/TajArchive.app"
}
trap cleanup EXIT

# --- Preflight -------------------------------------------------------------
step "Checking the signing setup"
IDENTITY_LINE="$(security find-identity -v -p codesigning | grep "Developer ID Application: .*($TEAM_ID)" | head -1 || true)"
[ -n "$IDENTITY_LINE" ] || die "No 'Developer ID Application' certificate for team $TEAM_ID in the keychain."
IDENTITY_HASH="$(echo "$IDENTITY_LINE" | awk '{print $2}')"
echo "    Signing identity: $(echo "$IDENTITY_LINE" | sed 's/.*"\(.*\)"/\1/')"

VERSION="$( (xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -showBuildSettings 2>/dev/null || true) | awk -F' = ' '/ MARKETING_VERSION =/{print $2; exit}')"
[ -n "$VERSION" ] || die "Could not read MARKETING_VERSION from $PROJECT"
echo "    Version: $VERSION"

NOTARIZE=yes
if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
    NOTARIZE=no
elif ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    if [ -t 0 ]; then
        echo ""
        echo "    Notarization is not set up yet. Without it, other Macs refuse to open the app."
        echo "    Create an app-specific password at https://appleid.apple.com"
        echo "    (Sign-In and Security → App-Specific Passwords), then paste it below."
        echo ""
        xcrun notarytool store-credentials "$NOTARY_PROFILE" --apple-id "$APPLE_ID" --team-id "$TEAM_ID" \
            || die "Could not store the notarization credentials."
    else
        NOTARIZE=no
    fi
fi
if [ "$NOTARIZE" = "yes" ]; then
    DMG_NAME="TajArchive-$VERSION.dmg"
else
    DMG_NAME="TajArchive-$VERSION-UNNOTARIZED.dmg"
    echo "    WARNING: building WITHOUT notarization — for testing on this Mac only."
fi

# --- Archive ---------------------------------------------------------------
step "Step 1/6: Archiving (Release, Apple silicon + Intel)"
rm -rf "$ARCHIVE_PATH"
mkdir -p "$WORK_DIR"
rm -rf "$BUILD_DIR/export" "$BUILD_DIR/TajArchive.xcarchive"  # layout of earlier versions
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    archive \
    -archivePath "$ARCHIVE_PATH" \
    -quiet \
    || die "xcodebuild archive failed. Fix the build errors above and re-run."

# --- Developer ID export ---------------------------------------------------
step "Step 2/6: Exporting with Developer ID"
cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>destination</key>
	<string>export</string>
</dict>
</plist>
PLIST
rm -rf "$EXPORT_DIR"
xcodebuild -exportArchive -archivePath "$ARCHIVE_PATH" -exportOptionsPlist "$EXPORT_PLIST" \
    -exportPath "$EXPORT_DIR" -quiet \
    || die "exportArchive failed. Check the Developer ID certificate for team $TEAM_ID."
APP="$EXPORT_DIR/TajArchive.app"
[ -d "$APP" ] || die "Export succeeded but $APP was not found."
forget_bundle "$APP"

codesign --verify --deep --strict "$APP" || die "The exported app does not pass codesign --verify."
for binary in "$APP/Contents/MacOS/TajArchive" "$APP/Contents/Resources/7zz" "$APP"/Contents/PlugIns/*.appex; do
    details="$(codesign -dvv "$binary" 2>&1)"
    echo "$details" | grep -q "Authority=Developer ID Application" || die "$binary is not signed with Developer ID."
    echo "$details" | grep -q "flags=.*runtime" || die "$binary lacks the hardened runtime."
done
echo "    Every binary is signed with Developer ID and the hardened runtime."
lipo -archs "$APP/Contents/MacOS/TajArchive" | grep -q x86_64 || echo "    Note: the app is not universal."

# --- Notarize the app --------------------------------------------------------
if [ "$NOTARIZE" = "yes" ]; then
    step "Step 3/6: Notarizing the app (usually a few minutes)"
    NOTARIZE_ZIP="$WORK_DIR/TajArchive-notarize.zip"
    rm -f "$NOTARIZE_ZIP"
    ditto -c -k --keepParent "$APP" "$NOTARIZE_ZIP"
    xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait \
        || die "Notarization failed. See: xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE"
    xcrun stapler staple "$APP" || die "Stapling the app failed."
    rm -f "$NOTARIZE_ZIP"
else
    step "Step 3/6: Notarization skipped"
fi

# --- Disk image ------------------------------------------------------------
step "Step 4/6: Building the disk image"
mkdir -p "$RELEASE_DIR"
DMG_PATH="$RELEASE_DIR/$DMG_NAME"
rm -f "$DMG_PATH"

VENV="$BUILD_DIR/.venv-dmgbuild"
if [ ! -x "$VENV/bin/dmgbuild" ]; then
    echo "    Installing dmgbuild (Finder window layout) into $VENV"
    { python3 -m venv "$VENV" && "$VENV/bin/pip" install --quiet --disable-pip-version-check 'dmgbuild>=1.6.1'; } \
        || echo "    Could not install dmgbuild; falling back to a plain disk image."
fi
if [ -x "$VENV/bin/dmgbuild" ]; then
    "$VENV/bin/dmgbuild" -s "$ROOT/Scripts/dmg_settings.py" \
        -D app="$APP" \
        -D background="$ROOT/Scripts/assets/dmg-background.tiff" \
        -D volume_icon="$ROOT/Scripts/assets/VolumeIcon.icns" \
        "TajArchive $VERSION" "$DMG_PATH" 2>&1 | grep -v 'deprecated' || true
fi
if [ ! -f "$DMG_PATH" ]; then
    STAGING="$WORK_DIR/dmg-staging"
    rm -rf "$STAGING"; mkdir -p "$STAGING"
    ditto "$APP" "$STAGING/TajArchive.app"
    ln -s /Applications "$STAGING/Applications"
    hdiutil create -volname "TajArchive $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH" \
        || die "hdiutil failed to create the disk image."
    rm -rf "$STAGING"
fi
codesign --force --sign "$IDENTITY_HASH" --timestamp "$DMG_PATH" || die "Signing the disk image failed."

# The copy inside the image must still carry an intact signature: anything that adds
# Finder info or resource forks on the way in makes Gatekeeper call the app damaged.
MOUNT_POINT="$(mktemp -d "${TMPDIR:-/tmp}/tajarchive-dmg.XXXXXX")"
hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT_POINT" "$DMG_PATH" >/dev/null 2>&1 \
    || die "Could not mount the disk image to check it."
if ! codesign --verify --deep --strict "$MOUNT_POINT/TajArchive.app" 2>/dev/null; then
    hdiutil detach "$MOUNT_POINT" -quiet || true
    die "The app inside the disk image no longer passes codesign --verify --strict."
fi
hdiutil detach "$MOUNT_POINT" -quiet || true
rmdir "$MOUNT_POINT" 2>/dev/null || true
echo "    The app inside the disk image keeps a valid signature."

# --- Notarize the disk image -------------------------------------------------
if [ "$NOTARIZE" = "yes" ]; then
    step "Step 5/6: Notarizing the disk image"
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait \
        || die "Notarizing the disk image failed."
    xcrun stapler staple "$DMG_PATH" || die "Stapling the disk image failed."
else
    step "Step 5/6: Notarization skipped"
fi

# --- Verify and package -------------------------------------------------------
step "Step 6/6: Verifying"
if [ "$NOTARIZE" = "yes" ]; then
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH" \
        || die "Gatekeeper rejects the disk image."
    spctl --assess --type execute --verbose=2 "$APP" || die "Gatekeeper rejects the app."
    xcrun stapler validate "$DMG_PATH" >/dev/null || die "The disk image has no stapled ticket."
    echo "    Gatekeeper accepts the disk image and the app."
fi

SOURCE_TARBALL="$ROOT/Vendor/7z2501-src.tar.xz"
if [ -f "$SOURCE_TARBALL" ]; then
    cp "$SOURCE_TARBALL" "$RELEASE_DIR/7-Zip-25.01-source.tar.xz"
fi
( cd "$RELEASE_DIR" && shasum -a 256 "$DMG_NAME" $( [ -f 7-Zip-25.01-source.tar.xz ] && echo 7-Zip-25.01-source.tar.xz ) > SHA256SUMS.txt )
cp "$DMG_PATH" "$HOME/Desktop/$DMG_NAME"

echo ""
echo "Release complete:"
echo "    $DMG_PATH  ($(du -h "$DMG_PATH" | cut -f1))"
echo "    copy on the Desktop: ~/Desktop/$DMG_NAME"
echo "    upload together with: 7-Zip-25.01-source.tar.xz, SHA256SUMS.txt"
if [ "$NOTARIZE" != "yes" ]; then
    echo ""
    echo "NOT NOTARIZED — other Macs will refuse to open this build."
    echo "Run this script in Terminal to set up notarization, or create the profile with:"
    echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id $APPLE_ID --team-id $TEAM_ID"
fi
