#!/bin/bash
# Mac App Store pipeline for TajArchive.
#
#   archive (AppStore configuration: sandboxed, APPSTORE flag) → export signed for the
#   App Store → upload to App Store Connect
#
# Signing is automatic and uses the Apple ID signed in to Xcode (Xcode → Settings →
# Accounts); -allowProvisioningUpdates lets Xcode create the distribution certificates
# and provisioning profiles it needs. The app record com.donishsoft.tajarchive must
# already exist in App Store Connect.
#
# Before each new upload raise the build number (CURRENT_PROJECT_VERSION) or the version
# (MARKETING_VERSION) in the Xcode project: App Store Connect accepts every build number
# only once per version.
#
# Usage:   Scripts/appstore.sh            archive, export and upload
#          Scripts/appstore.sh --export   archive and export the .pkg only (no upload)
#
# Environment overrides: TEAM_ID.

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
DESTINATION="upload"
[ "${1:-}" = "--export" ] && DESTINATION="export"

# ".noindex" keeps Spotlight from registering the intermediate app with Launch Services.
WORK_DIR="$ROOT/build/appstore.noindex"
ARCHIVE_PATH="$WORK_DIR/TajArchive.xcarchive"
EXPORT_DIR="$WORK_DIR/export"
EXPORT_PLIST="$WORK_DIR/ExportOptions.plist"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

[ -d "$PROJECT" ] || die "Xcode project not found at $ROOT/$PROJECT"

# The archived app must never become the copy macOS uses for the Finder menu or Quick Look.
cleanup() {
    local app="$ARCHIVE_PATH/Products/Applications/TajArchive.app"
    [ -d "$app" ] || return 0
    for appex in "$app"/Contents/PlugIns/*.appex; do
        [ -d "$appex" ] && pluginkit -r "$appex" 2>/dev/null || true
    done
    "$LSREGISTER" -u "$app" 2>/dev/null || true
}
trap cleanup EXIT

# --- Archive ---------------------------------------------------------------
step "Step 1/3: Archiving (AppStore, Apple silicon + Intel)"
rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR"
mkdir -p "$WORK_DIR"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration AppStore \
    -destination 'generic/platform=macOS' \
    archive \
    -archivePath "$ARCHIVE_PATH" \
    -allowProvisioningUpdates \
    -quiet \
    || die "xcodebuild archive failed. Fix the build errors above and re-run."

APP="$ARCHIVE_PATH/Products/Applications/TajArchive.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Contents/Info.plist")
echo "    TajArchive $VERSION ($BUILD)"

# The engine runs as a child process of the sandboxed app, so it must inherit the sandbox.
codesign -d --entitlements - "$APP/Contents/Resources/7zz" 2>/dev/null | grep -q "com.apple.security.inherit" \
    || die "7zz is not signed with the sandbox inherit entitlement (see the \"Sign 7zz helper\" build phase)."

# --- Export / upload -------------------------------------------------------
if [ "$DESTINATION" = "upload" ]; then
    step "Step 2/3: Exporting and uploading to App Store Connect"
else
    step "Step 2/3: Exporting the App Store package"
fi
cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>destination</key>
	<string>$DESTINATION</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
	<key>uploadSymbols</key>
	<false/>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE_PATH" -exportOptionsPlist "$EXPORT_PLIST" \
    -exportPath "$EXPORT_DIR" -allowProvisioningUpdates \
    || die "exportArchive failed. See the messages above."

# --- Done ------------------------------------------------------------------
step "Step 3/3: Done"
if [ "$DESTINATION" = "upload" ]; then
    echo "TajArchive $VERSION ($BUILD) was uploaded. It appears in App Store Connect →"
    echo "TajArchive → TestFlight after processing (usually 10–30 minutes); then select it"
    echo "on the version page and submit it for review."
else
    echo "Package: $EXPORT_DIR/TajArchive.pkg"
fi
