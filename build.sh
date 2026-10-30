#!/bin/zsh
# Builds Typestro.app into ./build using SwiftPM (universal: Apple Silicon + Intel), then signs it.
#
#   ./build.sh            release build, signed with your Developer ID if you have one
#   SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./build.sh
#                         signed with that identity plus a secure timestamp, ready to notarize
#                         (release.sh sets this)
#
# Local builds use the same Developer ID as releases on purpose: macOS ties the Accessibility and
# Microphone permissions to the signature, so a consistently signed app keeps them across rebuilds.
# An ad-hoc build ("-") has to be re-approved in System Settings after every build.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
swift build -c "$CONFIG" --arch arm64 --arch x86_64 --product Typestro
BIN_DIR="$(swift build -c "$CONFIG" --arch arm64 --arch x86_64 --show-bin-path)"

APP="build/Typestro.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Typestro" "$APP/Contents/MacOS/Typestro"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

ENTITLEMENTS=Resources/Typestro.entitlements
if [[ -n "${SIGN_ID:-}" ]]; then
  codesign --force --timestamp --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGN_ID" "$APP"
  echo "Built $APP (signed for release: $SIGN_ID)"
else
  LOCAL_ID="$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')"
  if [[ -n "$LOCAL_ID" ]]; then
    codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$LOCAL_ID" "$APP"
    echo "Built $APP (signed: $LOCAL_ID)"
  else
    codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign - --identifier com.mattmoglia.typestro "$APP"
    echo "Built $APP (ad-hoc signed; re-allow Accessibility after each build)"
  fi
fi
