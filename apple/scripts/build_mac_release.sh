#!/bin/bash
# Builds a signed, notarized Droprr.dmg for anyone's Mac (Developer ID).
#
# Needs, once per Mac:
#   - a "Developer ID Application" certificate (Xcode › Settings › Accounts › Manage Certificates › +)
#   - notary credentials saved in the Keychain under the profile name "droprr-notary":
#       xcrun notarytool store-credentials droprr-notary --apple-id <you> --team-id <team>
#   - Config/Local.xcconfig with your DEVELOPMENT_TEAM and DROPRR_BUNDLE_PREFIX
#
# Run from anywhere:  apple/scripts/build_mac_release.sh
# Output:             apple/build/release/Droprr-<version>.dmg
set -euo pipefail

APPLE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$APPLE/build/release"
PROFILE="${DROPRR_NOTARY_PROFILE:-droprr-notary}"
TEAM="$(sed -nE 's/^DEVELOPMENT_TEAM *= *([A-Z0-9]+).*/\1/p' "$APPLE/Config/Local.xcconfig")"
[ -n "$TEAM" ] || { echo "Set DEVELOPMENT_TEAM in apple/Config/Local.xcconfig" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"

echo "› Archiving"
xcodebuild -project "$APPLE/Droprr.xcodeproj" -scheme DroprrMac -configuration Release \
  -destination 'generic/platform=macOS' ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  -archivePath "$OUT/Droprr.xcarchive" -allowProvisioningUpdates archive -quiet

echo "› Exporting with Developer ID"
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$OUT/Droprr.xcarchive" -exportPath "$OUT/export" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates -quiet
APP="$OUT/export/Droprr.app"
codesign --verify --deep --strict "$APP"

VERSION="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)"
DMG="$OUT/Droprr-$VERSION.dmg"

echo "› Making the disk image"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Droprr" -srcfolder "$STAGE" -ov -format UDZO "$DMG" -quiet
codesign --sign "Developer ID Application" --timestamp "$DMG"

echo "› Notarizing (a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"

echo "✓ $DMG"
