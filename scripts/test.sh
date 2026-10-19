#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
bash scripts/prepare-vlc.sh
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/swift-cache"
swift build --build-tests --disable-sandbox --cache-path .build/package-cache
# VLCKit's fixed macOS binary uses an app-style install name. SwiftPM's test
# helper resets DYLD_FRAMEWORK_PATH, so prepare the test bundle's Frameworks path.
if [[ -d Vendor/VLCKit.xcframework/macos-arm64_x86_64 ]]; then
  BIN_DIR="$(swift build --disable-sandbox --show-bin-path --cache-path .build/package-cache)"
  for TEST_BUNDLE in "$BIN_DIR"/*.xctest; do
    [[ -d "$TEST_BUNDLE/Contents/MacOS" ]] || continue
    mkdir -p "$TEST_BUNDLE/Contents/Frameworks"
    ln -sfn "$PROJECT_DIR/Vendor/VLCKit.xcframework/macos-arm64_x86_64/VLCKit.framework" "$TEST_BUNDLE/Contents/Frameworks/VLCKit.framework"
  done
fi
swift test --skip-build --disable-sandbox --cache-path .build/package-cache "$@"
