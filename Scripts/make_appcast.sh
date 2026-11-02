#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
KEYFORGE_ARCHIVE="$1"
KEYFORGE_VERSION="$2"
# Never leave an older signed feed beside a newly built archive.
if [ -f dist/appcast.xml ]; then mv -f dist/appcast.xml dist/appcast.previous.xml; fi
KEYFORGE_PUBLIC_KEY="$(.build-deps/Sparkle/bin/generate_keys --account local.keyforge.updates -p 2>/dev/null || true)"
if [ "$KEYFORGE_PUBLIC_KEY" != "$(cat Updates/public-key.txt)" ]; then
  echo 'App built. Signed update feed requires the KeyForge publishing key in your login Keychain.'
  exit 0
fi
KEYFORGE_FEED_DIR="$(mktemp -d)"
trap 'rm -rf "$KEYFORGE_FEED_DIR"' EXIT
cp "$KEYFORGE_ARCHIVE" "$KEYFORGE_FEED_DIR/"
.build-deps/Sparkle/bin/generate_appcast --account local.keyforge.updates --maximum-deltas 0 \
  --download-url-prefix "https://github.com/silentrosehill/KeyForge/releases/download/v$KEYFORGE_VERSION/" \
  "$KEYFORGE_FEED_DIR"
cp "$KEYFORGE_FEED_DIR/appcast.xml" dist/appcast.xml
swift Scripts/verify_updates.swift Updates/public-key.txt "$KEYFORGE_ARCHIVE" dist/appcast.xml
echo 'Publish dist/appcast.xml alongside the app ZIP for in-app updates.'
