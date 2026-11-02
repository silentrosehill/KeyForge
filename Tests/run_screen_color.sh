#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 5 -parse-as-library Sources/ScreenColorGrid.swift Tests/ScreenColorGridTests.swift -o "$TEST_DIR/screen-color-tests"
"$TEST_DIR/screen-color-tests"
