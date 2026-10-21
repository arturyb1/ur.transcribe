#!/bin/bash
# Builds a release that opens without Gatekeeper warnings: signed with a
# Developer ID, notarized by Apple, stapled, and packaged as a DMG and a zip.
#
# One-time setup (see docs/RELEASING.md):
#   1. A "Developer ID Application" certificate in your keychain.
#   2. Notary credentials saved under a keychain profile:
#        xcrun notarytool store-credentials urtranscribe-notary --apple-id YOU --team-id TEAMID
#
# Then:
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" scripts/release.sh
#   DEVELOPER_ID="..." scripts/release.sh --upload    # also attach to the GitHub release
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
: "${DEVELOPER_ID:?Set DEVELOPER_ID to your Developer ID Application identity}"
PROFILE="${NOTARY_PROFILE:-urtranscribe-notary}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
APP="$ROOT/build/ur.transcribe.app"
NAME="ur.transcribe-$VERSION-macos-arm64"
ZIP="$ROOT/build/$NAME.zip"
DMG="$ROOT/build/$NAME.dmg"

echo "==> Building and signing $VERSION"
SIGN_IDENTITY="$DEVELOPER_ID" scripts/build-app.sh
codesign --verify --strict --deep "$APP"

echo "==> Notarizing the app"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"

# Re-zip so the zip carries the stapled ticket too.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Building the DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "ur.transcribe" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --sign "$DEVELOPER_ID" --timestamp "$DMG"

echo "==> Notarizing the DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

echo "==> Checking Gatekeeper"
spctl --assess --type execute --verbose "$APP"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"

shasum -a 256 "$DMG" "$ZIP"

if [[ "${1:-}" == "--upload" ]]; then
  echo "==> Uploading to GitHub release v$VERSION"
  gh release upload "v$VERSION" "$DMG" "$ZIP" --clobber
fi
echo "Done: $DMG"
