#!/bin/bash
# Builds an ad-hoc signed Droprr.dmg that any Mac can run without a Developer ID. macOS blocks it the first time;
# the person allows it in System Settings › Privacy & Security › Open Anyway. Use build_mac_release.sh once a
# Developer ID certificate is available.
#
# Ad-hoc signing can't carry the keychain-access-groups entitlement (it needs a provisioning profile), so this
# build keeps its tokens in the app group's settings instead of the Keychain (TokenStore's fallback).
#
# Run from anywhere:  apple/scripts/build_mac_adhoc.sh
# Output:             apple/build/adhoc/Droprr-<version>-unsigned.dmg
set -euo pipefail

APPLE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$APPLE/build/adhoc"
TEAM="$(sed -nE 's/^DEVELOPMENT_TEAM *= *([A-Z0-9]+).*/\1/p' "$APPLE/Config/Local.xcconfig")"
[ -n "$TEAM" ] || { echo "Set DEVELOPMENT_TEAM in apple/Config/Local.xcconfig" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"

echo "› Building (unsigned)"
xcodebuild -project "$APPLE/Droprr.xcodeproj" -scheme DroprrMac -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$OUT/dd" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO -quiet build
APP="$OUT/Droprr.app"
cp -R "$OUT/dd/Build/Products/Release/Droprr.app" "$APP"

echo "› Signing ad hoc"
# The project's entitlements, with the app group filled in and keychain-access-groups left out.
entitlements() {
  local src="$1" dest="$2"
  sed "s/\$(DROPRR_MAC_APP_GROUP)/$TEAM.droprr/g" "$src" > "$dest"
  /usr/libexec/PlistBuddy -c "Delete :keychain-access-groups" "$dest" 2>/dev/null || true
}
entitlements "$APPLE/Config/MacShare.entitlements" "$OUT/share.entitlements"
entitlements "$APPLE/Config/Mac.entitlements" "$OUT/app.entitlements"
for appex in "$APP"/Contents/PlugIns/*.appex; do
  codesign --force --sign - --entitlements "$OUT/share.entitlements" "$appex"
done
codesign --force --sign - --entitlements "$OUT/app.entitlements" "$APP"
codesign --verify --deep --strict "$APP"

VERSION="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)"
DMG="$OUT/Droprr-$VERSION-unsigned.dmg"

echo "› Making the disk image"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Droprr" -srcfolder "$STAGE" -ov -format UDZO "$DMG" -quiet

echo "✓ $DMG"
