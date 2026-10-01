#!/bin/bash
# Builds KeyForge.app next to this script.
set -euo pipefail
cd "$(dirname "$0")"

APP="KeyForge.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
[ -f Icon/AppIcon.icns ] && cp Icon/AppIcon.icns "$APP/Contents/Resources/"

OBJ="$(mktemp -d)"
clang -O -c Sources/RazerUSB.c -o "$OBJ/RazerUSB.o"
swiftc -O -wmo -parse-as-library -swift-version 5 \
  Sources/*.swift "$OBJ/RazerUSB.o" \
  -o "$APP/Contents/MacOS/KeyForge"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>KeyForge</string>
  <key>CFBundleDisplayName</key><string>KeyForge</string>
  <key>CFBundleIdentifier</key><string>local.keyforge</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>KeyForge</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.7.1</string>
  <key>CFBundleVersion</key><string>17</string>
  <key>NSHumanReadableCopyright</key><string>Key remapping and profiles for the Razer Huntsman V2 — built with Claude.</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAudioCaptureUsageDescription</key><string>KeyForge listens to what your Mac plays so the Music lighting effect can dance to it. Nothing is recorded or saved.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature with a fixed designated requirement (the bundle ID) instead of the default
# "this exact build" hash, so Accessibility / audio permissions keep working after updates.
codesign --force --sign - --requirements '=designated => identifier "local.keyforge"' "$APP" >/dev/null
echo "Built $(pwd)/$APP"
