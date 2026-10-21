#!/bin/bash
# Builds ur.transcribe.app into ./build.
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
APP="$ROOT/build/ur.transcribe.app"
IDENTITY="${SIGN_IDENTITY:--}"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/URTranscribe" "$APP/Contents/MacOS/URTranscribe"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
for bundle in "$BIN"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done
# Sparkle (auto-updates). ditto keeps the framework's symlinks intact.
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

# Real identities get the hardened runtime and a secure timestamp, which
# notarization requires. Ad-hoc builds skip the hardened runtime: its library
# validation would refuse to load the ad-hoc signed Sparkle framework.
SIGN=(codesign --force --sign "$IDENTITY")
[[ "$IDENTITY" != "-" ]] && SIGN+=(--options runtime --timestamp)

# Sign inside out, as Sparkle documents: its helpers, the framework, then the app.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
"${SIGN[@]}" "$SPARKLE/XPCServices/Installer.xpc"
"${SIGN[@]}" --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
"${SIGN[@]}" "$SPARKLE/Autoupdate"
"${SIGN[@]}" "$SPARKLE/Updater.app"
"${SIGN[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
"${SIGN[@]}" --entitlements "$ROOT/Resources/URTranscribe.entitlements" "$APP"
codesign --verify --strict --deep "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x URTranscribe 2>/dev/null || true
  rm -rf /Applications/ur.transcribe.app
  cp -R "$APP" /Applications/
  echo "Installed /Applications/ur.transcribe.app"
fi
