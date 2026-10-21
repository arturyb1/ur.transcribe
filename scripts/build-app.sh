#!/bin/bash
# Builds Earshot.app into ./build.
#
#   scripts/build-app.sh                 # release build, ad-hoc signed
#   SIGN_IDENTITY="Developer ID Application: You (TEAMID)" scripts/build-app.sh
#   scripts/build-app.sh --install       # also copy to /Applications
#
# Ad-hoc signed builds work, but macOS ties permissions to the exact build, so
# you will be asked again after each rebuild. A real signing identity avoids that.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/build/Earshot.app"
IDENTITY="${SIGN_IDENTITY:--}"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Earshot" "$APP/Contents/MacOS/Earshot"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
for bundle in "$BIN"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

codesign --force --deep --options runtime \
  --entitlements "$ROOT/Resources/Earshot.entitlements" \
  --sign "$IDENTITY" "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Earshot 2>/dev/null || true
  rm -rf /Applications/Earshot.app
  cp -R "$APP" /Applications/
  echo "Installed /Applications/Earshot.app"
fi
