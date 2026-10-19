#!/bin/bash
set -euo pipefail
offline_project="$(cd "$(dirname "$0")/.." && pwd)"
cd "$offline_project"
offline_prebuilt=""
if [[ "${1:-}" == "--prebuilt" ]]; then
  offline_prebuilt="$2"
  shift 2
fi
offline_work="${OFFLINE_SMOKE_WORKDIR:-$(mktemp -d "${TMPDIR:-/tmp}/shelf-offline-live.XXXXXX")}"
mkdir -p "$offline_work"
offline_vlc="$offline_project/Vendor/VLCKit.xcframework/macos-arm64_x86_64"
if [[ ! -d "$offline_vlc/VLCKit.framework" ]]; then
  echo "VLCKit 3.7.3 is required; run scripts/prepare-vlc.sh first." >&2
  exit 1
fi
if [[ -z "$offline_prebuilt" ]]; then
  swift build --product AudilsePlayback --disable-sandbox --cache-path .build/package-cache
  offline_prebuilt="$(swift build --show-bin-path --disable-sandbox --cache-path .build/package-cache)"
fi
swiftc -parse-as-library -swift-version 6 -disable-sandbox \
  -module-cache-path "$offline_work/module-cache" \
  -I "$offline_prebuilt" -I "$offline_project/.build/checkouts/GRDB.swift/Sources/GRDBSQLite" \
  -F "$offline_vlc" -framework VLCKit \
  "$offline_project/scripts/offline-live-smoke.swift" "$offline_prebuilt/libAudilsePlayback.a" \
  -lsqlite3 -o "$offline_work/OfflineLiveSmoke"
if [[ -d "$offline_prebuilt/GRDB_GRDB.bundle" ]]; then cp -R "$offline_prebuilt/GRDB_GRDB.bundle" "$offline_work/"; fi
echo "Acceptance work directory (retained): $offline_work"
echo "This opt-in test downloads real originals and records a few seconds of actual listening."
echo "Enter the server URL, username and password on stdin when prompted. Credentials are never saved."
DYLD_FRAMEWORK_PATH="$offline_vlc${DYLD_FRAMEWORK_PATH:+:$DYLD_FRAMEWORK_PATH}" \
  "$offline_work/OfflineLiveSmoke" run "$offline_work" "$@"
