#!/bin/bash
set -euo pipefail
localization_project="$(cd "$(dirname "$0")/.." && pwd)"
localization_work="$(mktemp -d "${TMPDIR:-/tmp}/shelf-localization-smoke.XXXXXX")"
localization_prebuilt="${LOCALIZATION_SMOKE_PREBUILT:-$localization_project/.build/debug}"
localization_vlc="$localization_project/Vendor/VLCKit.xcframework/macos-arm64_x86_64"
mkdir -p "$localization_work/dependencies"
for localization_file in libAudilseCore.a libAudilsePlayback.a AudilseCore.swiftmodule AudilsePlayback.swiftmodule GRDB.swiftmodule SocketIO.swiftmodule Starscream.swiftmodule; do
  cp -R "$localization_prebuilt/$localization_file" "$localization_work/dependencies/"
done
for localization_language in en zh-Hans; do
  cp -R "$localization_project/Sources/Audilse/Resources/$localization_language.lproj" "$localization_work/"
done
swiftc -parse-as-library -swift-version 6 \
  -module-cache-path "$localization_work/module-cache" \
  -I "$localization_work/dependencies" \
  -I "$localization_project/.build/checkouts/GRDB.swift/Sources/GRDBSQLite" \
  -F "$localization_vlc" -framework VLCKit \
  "$localization_project/Sources/Audilse/Localization/AppLanguage.swift" \
  "$localization_project/Sources/Audilse/Localization/ErrorLocalization.swift" \
  "$localization_project/scripts/localization-smoke.swift" \
  "$localization_work/dependencies/libAudilsePlayback.a" \
  -lsqlite3 -o "$localization_work/LocalizationSmoke"
DYLD_FRAMEWORK_PATH="$localization_vlc${DYLD_FRAMEWORK_PATH:+:$DYLD_FRAMEWORK_PATH}" "$localization_work/LocalizationSmoke"
