#!/bin/bash
set -euo pipefail
audio_project="$(cd "$(dirname "$0")/.." && pwd)"
cd "$audio_project"
audio_work="$(mktemp -d "${TMPDIR:-/tmp}/shelf-audio-smoke.XXXXXX")"
trap 'rm -rf "$audio_work"' EXIT
audio_vlc="$audio_project/Vendor/VLCKit.xcframework/macos-arm64_x86_64"
if [[ ! -d "$audio_vlc/VLCKit.framework" ]]; then
  echo "VLCKit 3.7.3 is required. Run scripts/prepare-vlc.sh first." >&2
  exit 1
fi
export CLANG_MODULE_CACHE_PATH="$audio_project/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$audio_project/.build/swift-cache"
# Rebuild the static product together with its Swift modules: an application
# build can refresh modules without refreshing a previously created archive.
swift build --product AudilsePlayback --disable-sandbox --cache-path .build/package-cache
audio_bin="$(swift build --show-bin-path --disable-sandbox --cache-path .build/package-cache)"
swiftc -parse-as-library -swift-version 6 -disable-sandbox \
  -module-cache-path "$audio_work/module-cache" \
  -I "$audio_bin" -I "$audio_project/.build/checkouts/GRDB.swift/Sources/GRDBSQLite" \
  -F "$audio_vlc" -framework VLCKit \
  "$audio_project/scripts/audio-smoke.swift" "$audio_bin/libAudilsePlayback.a" \
  -lsqlite3 -o "$audio_work/AudioSmoke"
DYLD_FRAMEWORK_PATH="$audio_vlc${DYLD_FRAMEWORK_PATH:+:$DYLD_FRAMEWORK_PATH}" "$audio_work/AudioSmoke"
