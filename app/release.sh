#!/usr/bin/env bash
# Builds a signed, notarized GazeSwitch-<version>.zip in dist/ for a GitHub release.
#
#   VERSION=0.2.0 \
#   SIGN_IDENTITY="Developer ID Application: …" \
#   NOTARY_PROFILE=<name> \     # once: xcrun notarytool store-credentials <name>
#   ./release.sh
set -euo pipefail
cd "$(dirname "$0")"

: "${VERSION:?set VERSION}"
: "${SIGN_IDENTITY:?set SIGN_IDENTITY}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE}"

mkdir -p dist
APP=dist/GazeSwitch.app
ZIP=dist/GazeSwitch-$VERSION.zip
rm -rf "$APP" "$ZIP"

UNIVERSAL=1 APP=$APP ./bundle.sh

# Notarize a zip of the app, staple the ticket to the app, then zip again so
# the download carries the ticket and opens offline.
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
rm "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

spctl --assess --type execute --verbose "$APP"
echo "Ready: $ZIP"
