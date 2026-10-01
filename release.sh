#!/bin/bash
# Builds a universal (Apple silicon + Intel, macOS 15+) KeyForge.app and zips it into dist/ for a GitHub release.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh >/dev/null            # app bundle, Info.plist, icon
APP="KeyForge.app"
BIN="$APP/Contents/MacOS/KeyForge"
TMP=$(mktemp -d)
for arch in arm64 x86_64; do
  clang -O -arch "$arch" -mmacosx-version-min=15.0 -c Sources/RazerUSB.c -o "$TMP/RazerUSB-$arch.o"
  swiftc -O -wmo -parse-as-library -swift-version 5 -target "$arch-apple-macos15" \
    Sources/*.swift "$TMP/RazerUSB-$arch.o" -o "$TMP/$arch"
done
lipo -create "$TMP/arm64" "$TMP/x86_64" -output "$BIN"
rm -rf "$TMP"
# same stable identity as build.sh, so permissions survive updates
codesign --force --sign - --requirements '=designated => identifier "local.keyforge"' "$APP" >/dev/null

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
mkdir -p dist
ZIP="dist/KeyForge-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Built $ZIP"
