#!/usr/bin/env bash
# Builds GazeSwitch.app next to this script.
# The camera prompt only works from a bundle with NSCameraUsageDescription,
# so don't run the bare `swift run` binary for real use.
#
# Optional environment:
#   VERSION=0.2.0             version written into the bundle
#   UNIVERSAL=1               build for both Apple silicon and Intel
#   SIGN_IDENTITY="Developer ID Application: …"
#                             sign for distribution (default: ad-hoc, local use)
#   APP=path/GazeSwitch.app   where to put the bundle
set -euo pipefail
cd "$(dirname "$0")"

VERSION=${VERSION:-0.2.0}
SIGN_IDENTITY=${SIGN_IDENTITY:--}
APP=${APP:-GazeSwitch.app}

# Keep this machine's paths out of the binary.
FLAGS=(-c release -Xswiftc -file-prefix-map -Xswiftc "$PWD=.")
if [[ ${UNIVERSAL:-0} == 1 ]]; then FLAGS+=(--arch arm64 --arch x86_64); fi
swift build "${FLAGS[@]}"
BIN=$(swift build "${FLAGS[@]}" --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/GazeSwitch" "$APP/Contents/MacOS/GazeSwitch"
mkdir -p "$APP/Contents/Resources"
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # redraw with icon/make-icns.sh

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>GazeSwitch</string>
  <key>CFBundleIdentifier</key><string>io.github.aimdevlee.GazeSwitch</string>
  <key>CFBundleExecutable</key><string>GazeSwitch</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key>
  <array><string>en</string><string>ko</string><string>ja</string></array>
  <key>NSCameraUsageDescription</key>
  <string>GazeSwitch watches where your face is turned to switch the keyboard's output between this Mac and the other computer. Video is never stored or sent.</string>
</dict>
</plist>
PLIST

# The camera prompt is shown by macOS, in the system language.
camera_text() {
  mkdir -p "$APP/Contents/Resources/$1.lproj"
  printf '"NSCameraUsageDescription" = "%s";\n' "$2" > "$APP/Contents/Resources/$1.lproj/InfoPlist.strings"
}
camera_text en "GazeSwitch watches where your face is turned to switch the keyboard's output between this Mac and the other computer. Video is never stored or sent."
camera_text ko "얼굴 방향을 보고 키보드의 출력을 이 맥과 다른 컴퓨터 사이에서 전환합니다. 영상은 저장하거나 전송하지 않습니다."
camera_text ja "顔の向きを見て、キーボードの出力をこの Mac ともう一台のコンピュータの間で切り替えます。映像は保存も送信もしません。"

if [[ $SIGN_IDENTITY == - ]]; then
  # Ad-hoc signature so macOS remembers the camera permission between launches.
  codesign --force --sign - "$APP"
else
  # Distribution: the hardened runtime is required for notarization, and with
  # it the camera needs an explicit entitlement.
  codesign --force --options runtime --timestamp \
    --entitlements GazeSwitch.entitlements --sign "$SIGN_IDENTITY" "$APP"
fi
echo "Built $APP"
