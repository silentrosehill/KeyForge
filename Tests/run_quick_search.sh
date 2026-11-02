#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
KEYFORGE_TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$KEYFORGE_TEST_DIR"' EXIT
# Compile the real models and UI with a test entry point, leaving App.swift untouched.
python3 - "$KEYFORGE_TEST_DIR/AppForTests.swift" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).write_text(Path('Sources/App.swift').read_text().replace('@main\nstruct KeyForgeApp', 'struct KeyForgeApp', 1))
PY
clang -O -c Sources/RazerUSB.c -o "$KEYFORGE_TEST_DIR/usb.o"
KEYFORGE_TEST_SOURCES=()
for src in Sources/*.swift; do
  [ "$src" = "Sources/App.swift" ] || KEYFORGE_TEST_SOURCES+=("$src")
done
swiftc -swift-version 5 -parse-as-library -F .build-deps/Sparkle -framework Sparkle \
  -Xlinker -rpath -Xlinker "$(pwd)/.build-deps/Sparkle" \
  "${KEYFORGE_TEST_SOURCES[@]}" "$KEYFORGE_TEST_DIR/AppForTests.swift" Tests/QuickSearchTests.swift \
  "$KEYFORGE_TEST_DIR/usb.o" -o "$KEYFORGE_TEST_DIR/search-tests"
KEYFORGE_DRY=1 KEYFORGE_PROFILES="$KEYFORGE_TEST_DIR/profiles.json" "$KEYFORGE_TEST_DIR/search-tests"
