#!/bin/zsh
# Cuts a public release:
#   1. stamps the version into Info.plist
#   2. builds, signs with Developer ID, notarizes with Apple, staples
#   3. zips to dist/Typestro-<version>.zip
#   4. creates a GitHub release with the zip attached
#
# Usage: ./release.sh 1.1 "Short release notes"
#
# One-time setup (see README, "Releasing"):
#   - a "Developer ID Application" certificate in your login keychain
#   - a notarytool keychain profile. The one made for AudioPin works for every app on the same
#     Apple ID, so it's the default; set NOTARY_PROFILE to use another.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage: ./release.sh <version> [notes]}"
NOTES="${2:-Typestro $VERSION}"
PROFILE="${NOTARY_PROFILE:-AudioPin}"

SIGN_ID="$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')"
if [[ -z "$SIGN_ID" ]]; then
  echo "No 'Developer ID Application' certificate in the keychain. See README > Releasing." >&2
  exit 1
fi

# Version = what people see; build = a number that always goes up.
BUILD="$(date +%Y%m%d%H%M)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" Resources/Info.plist

SIGN_ID="$SIGN_ID" ./build.sh release

mkdir -p dist
ZIP="dist/Typestro-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/Typestro.app "$ZIP"

echo "Submitting to Apple for notarization (usually 1-5 minutes)..."
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple build/Typestro.app
# Re-zip so the stapled ticket is inside the download.
rm -f "$ZIP"
ditto -c -k --keepParent build/Typestro.app "$ZIP"
spctl --assess --type execute --verbose=2 build/Typestro.app

git add Resources/Info.plist
git commit -q -m "Release $VERSION" || true
git tag -f "v$VERSION"
git push -q origin HEAD --tags

gh release create "v$VERSION" "$ZIP" --title "Typestro $VERSION" --notes "$NOTES"
echo "Released Typestro $VERSION"
