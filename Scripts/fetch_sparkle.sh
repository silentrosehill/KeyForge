#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
KEYFORGE_SPARKLE_VERSION="2.10.1"
KEYFORGE_SPARKLE_HASH="1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27"
KEYFORGE_SPARKLE_DIR=".build-deps/Sparkle"
if [ -f "$KEYFORGE_SPARKLE_DIR/.version" ] && [ "$(cat "$KEYFORGE_SPARKLE_DIR/.version")" = "$KEYFORGE_SPARKLE_VERSION" ] && [ -d "$KEYFORGE_SPARKLE_DIR/Sparkle.framework" ]; then
  codesign --verify --deep --strict "$KEYFORGE_SPARKLE_DIR/Sparkle.framework"
  exit 0
fi
KEYFORGE_DOWNLOAD_DIR="$(mktemp -d)"
trap 'rm -rf "$KEYFORGE_DOWNLOAD_DIR"' EXIT
curl -fsSL --proto '=https' --tlsv1.2 --retry 2 \
  "https://github.com/sparkle-project/Sparkle/releases/download/$KEYFORGE_SPARKLE_VERSION/Sparkle-$KEYFORGE_SPARKLE_VERSION.tar.xz" \
  -o "$KEYFORGE_DOWNLOAD_DIR/Sparkle.tar.xz"
printf '%s  %s\n' "$KEYFORGE_SPARKLE_HASH" "$KEYFORGE_DOWNLOAD_DIR/Sparkle.tar.xz" | shasum -a 256 -c -
mkdir -p "$KEYFORGE_SPARKLE_DIR"
tar -xf "$KEYFORGE_DOWNLOAD_DIR/Sparkle.tar.xz" -C "$KEYFORGE_SPARKLE_DIR"
codesign --verify --deep --strict "$KEYFORGE_SPARKLE_DIR/Sparkle.framework"
printf '%s\n' "$KEYFORGE_SPARKLE_VERSION" > "$KEYFORGE_SPARKLE_DIR/.version"
