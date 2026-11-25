#!/usr/bin/env bash
# Builds GazeSwitch.app next to this script.
# The camera prompt only works from a bundle with NSCameraUsageDescription,
# so don't run the bare `swift run` binary for real use.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP=GazeSwitch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/GazeSwitch "$APP/Contents/MacOS/GazeSwitch"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>GazeSwitch</string>
  <key>CFBundleIdentifier</key><string>io.github.aimdevlee.GazeSwitch</string>
  <key>CFBundleExecutable</key><string>GazeSwitch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
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

# Ad-hoc signature so macOS remembers the camera permission between launches.
codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP"
