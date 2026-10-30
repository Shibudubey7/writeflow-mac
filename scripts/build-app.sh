#!/bin/sh
# Builds dist/WriteFlow.app (Apple silicon and Intel) and dist/WriteFlow-<version>.zip for GitHub Releases.
#   sh scripts/build-app.sh
# The app is signed ad hoc (no Apple Developer account), so people opening the download for the
# first time have to allow it once in System Settings; see README.md.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
APP="dist/WriteFlow.app"
ICONSET=".build/AppIcon.iconset"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/WriteFlow"

rm -rf "$APP" "$ICONSET"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ICONSET"
cp "$BIN" "$APP/Contents/MacOS/WriteFlow"
cp Resources/Info.plist "$APP/Contents/Info.plist"

swift scripts/make-icon.swift "$ICONSET/icon_512x512@2x.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  [ $s = 512 ] || sips -z $((s * 2)) $((s * 2)) "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"
rm -f "dist/WriteFlow-$VERSION.zip"
ditto -c -k --keepParent "$APP" "dist/WriteFlow-$VERSION.zip"
echo "Built $APP and dist/WriteFlow-$VERSION.zip"
