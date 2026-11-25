#!/usr/bin/env bash
# Builds signed, notarized GazeSwitch-<version>.dmg and .zip in dist/ for a
# GitHub release. .github/workflows/release.yml runs this on every v* tag.
#
#   VERSION=0.2.0 \
#   SIGN_IDENTITY="Developer ID Application: …" \
#   NOTARY_PROFILE=<name> \     # once: xcrun notarytool store-credentials <name>
#   ./release.sh
#
# Optional: NOTARY_KEYCHAIN=<path>, when the profile is not in the login keychain.
set -euo pipefail
cd "$(dirname "$0")"

: "${VERSION:?set VERSION}"
: "${SIGN_IDENTITY:?set SIGN_IDENTITY}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE}"

NOTARY=(--keychain-profile "$NOTARY_PROFILE")
if [[ -n ${NOTARY_KEYCHAIN:-} ]]; then NOTARY+=(--keychain "$NOTARY_KEYCHAIN"); fi

mkdir -p dist
APP=dist/GazeSwitch.app
ZIP=dist/GazeSwitch-$VERSION.zip
DMG=dist/GazeSwitch-$VERSION.dmg
STAGE=dist/dmg
rm -rf "$APP" "$ZIP" "$DMG" "$STAGE"

UNIVERSAL=1 APP=$APP ./bundle.sh

# Notarize a zip of the app, staple the ticket to the app, then zip again so
# the download carries the ticket and opens offline.
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" "${NOTARY[@]}" --wait
xcrun stapler staple "$APP"
rm "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# The disk image holds the stapled app next to a shortcut to Applications.
# It is a separate file, so it gets its own signature and ticket.
mkdir "$STAGE"
ditto "$APP" "$STAGE/GazeSwitch.app"
ln -s /Applications "$STAGE/Applications"
for attempt in 1 2 3; do
  # hdiutil now and then reports "Resource busy" on CI runners.
  hdiutil create -volname GazeSwitch -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" && break
  [[ $attempt == 3 ]] && exit 1
  sleep 5
done
rm -rf "$STAGE"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" "${NOTARY[@]}" --wait
xcrun stapler staple "$DMG"

spctl --assess --type execute --verbose "$APP"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"
echo "Ready: $DMG $ZIP"
