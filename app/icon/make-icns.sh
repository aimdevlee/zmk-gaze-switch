#!/usr/bin/env bash
# Redraws AppIcon.icns from make-icon.swift. Run after changing the drawing.
set -euo pipefail
cd "$(dirname "$0")"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
swift make-icon.swift "$TMP/1024.png"

SET=$TMP/AppIcon.iconset
mkdir "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/1024.png" --out "$SET/icon_${s}x${s}.png" > /dev/null
  sips -z $((s * 2)) $((s * 2)) "$TMP/1024.png" --out "$SET/icon_${s}x${s}@2x.png" > /dev/null
done
iconutil -c icns "$SET" -o AppIcon.icns
echo "Wrote icon/AppIcon.icns"
