#!/bin/bash
# Builds a release that opens without Gatekeeper warnings: signed with a
# Developer ID, notarized by Apple, stapled, and packaged as a DMG and a zip.
#
# One-time setup (see docs/RELEASING.md):
#   1. A "Developer ID Application" certificate in your keychain.
#   2. Notary credentials saved under a keychain profile:
#        xcrun notarytool store-credentials urtranscribe-notary --apple-id YOU --team-id TEAMID
#
#   3. A Sparkle update signing key (scripts/release.sh uses account "urtranscribe"):
#        .build/artifacts/sparkle/Sparkle/bin/generate_keys --account urtranscribe
#
# Then:
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" scripts/release.sh
#   DEVELOPER_ID="..." scripts/release.sh --upload
#
# --upload attaches the DMG and zip to the existing GitHub release v<version>
# (create it with notes first), signs the zip for Sparkle, adds it to
# appcast.xml, and pushes the feed so installed copies update themselves.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
: "${DEVELOPER_ID:?Set DEVELOPER_ID to your Developer ID Application identity}"
PROFILE="${NOTARY_PROFILE:-urtranscribe-notary}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-urtranscribe}"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Resources/Info.plist)"
REPO="arturyb1/ur.transcribe"
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
  gh release upload "v$VERSION" "$DMG" "$ZIP" --clobber --repo "$REPO"

  echo "==> Publishing the update to the appcast"
  SIGNATURE="$(.build/artifacts/sparkle/Sparkle/bin/sign_update --account "$SPARKLE_ACCOUNT" "$ZIP")"
  NOTES="$(mktemp)"
  gh release view "v$VERSION" --repo "$REPO" --json body -q .body \
    | gh api markdown -F text=@- -f mode=gfm -f context="$REPO" > "$NOTES"
  python3 scripts/update-appcast.py \
    --version "$VERSION" --build "$BUILD" \
    --url "https://github.com/$REPO/releases/download/v$VERSION/$NAME.zip" \
    --signature "$SIGNATURE" --notes-html "$NOTES" \
    --link "https://github.com/$REPO/releases/tag/v$VERSION"
  rm -f "$NOTES"
  git add appcast.xml
  git commit -m "appcast: $VERSION"
  git push
fi
echo "Done: $DMG"
