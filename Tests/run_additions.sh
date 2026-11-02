#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
KEYFORGE_TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$KEYFORGE_TEST_DIR"' EXIT
./Tests/run_screen_color.sh
swiftc -swift-version 5 -parse-as-library Sources/EditHistory.swift Tests/EditHistoryTests.swift -o "$KEYFORGE_TEST_DIR/history"
"$KEYFORGE_TEST_DIR/history"
swiftc -swift-version 5 -parse-as-library Sources/UpdateVersion.swift Tests/UpdateVersionTests.swift -o "$KEYFORGE_TEST_DIR/version"
"$KEYFORGE_TEST_DIR/version"
