#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
KEYFORGE_TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$KEYFORGE_TEST_DIR"' EXIT
swiftc Sources/LightingLayers.swift Tests/LightingLayersTests.swift -o "$KEYFORGE_TEST_DIR/tests"
"$KEYFORGE_TEST_DIR/tests"
