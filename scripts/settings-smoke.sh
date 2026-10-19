#!/bin/bash
set -euo pipefail
settings_project="$(cd "$(dirname "$0")/.." && pwd)"
settings_prebuilt="${SETTINGS_SMOKE_PREBUILT:-$settings_project/.build/debug}"
settings_work="$(mktemp -d "${TMPDIR:-/tmp}/shelf-settings-smoke.XXXXXX")"
mkdir -p "$settings_work/dependencies"
for settings_file in libShelfCore.a ShelfCore.swiftmodule GRDB.swiftmodule SocketIO.swiftmodule Starscream.swiftmodule; do
  cp -R "$settings_prebuilt/$settings_file" "$settings_work/dependencies/"
done
for settings_language in en zh-Hans; do
  cp -R "$settings_project/Sources/ShelfMac/Resources/$settings_language.lproj" "$settings_work/"
done
swiftc -parse-as-library -swift-version 6 -disable-sandbox \
  -module-cache-path "$settings_work/module-cache" \
  -I "$settings_work/dependencies" \
  -I "$settings_project/.build/checkouts/GRDB.swift/Sources/GRDBSQLite" \
  "$settings_project/scripts/settings-smoke.swift" \
  "$settings_project/Sources/ShelfMac/Localization/AppLanguage.swift" \
  "$settings_project/Sources/ShelfMac/Management/SettingsChoicePicker.swift" \
  "$settings_project/Sources/ShelfMac/Personal/PersonalPlaybackPreferencesStore.swift" \
  "$settings_project/Sources/ShelfMac/ServerAdmin/ServerSettingOptions.swift" \
  "$settings_work/dependencies/libShelfCore.a" -lsqlite3 -o "$settings_work/SettingsSmoke"
"$settings_work/SettingsSmoke"
