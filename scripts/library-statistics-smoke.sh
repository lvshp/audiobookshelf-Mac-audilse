#!/bin/bash
set -euo pipefail
stats_project="$(cd "$(dirname "$0")/.." && pwd)"
stats_prebuilt="${LIBRARY_STATISTICS_SMOKE_PREBUILT:-$stats_project/.build/debug}"
stats_work="${LIBRARY_STATISTICS_SMOKE_WORKDIR:-$(mktemp -d "${TMPDIR:-/tmp}/shelf-library-statistics-smoke.XXXXXX")}"
mkdir -p "$stats_work/dependencies"
for stats_file in libShelfCore.a ShelfCore.swiftmodule GRDB.swiftmodule SocketIO.swiftmodule Starscream.swiftmodule; do
  stats_source="$stats_prebuilt/$stats_file"
  if [[ ! -e "$stats_source" && -e "$stats_prebuilt/dependencies/$stats_file" ]]; then stats_source="$stats_prebuilt/dependencies/$stats_file"; fi
  if [[ ! -e "$stats_source" ]]; then echo "Matching Core archive/modules required; no shared build is run." >&2; exit 2; fi
  cp -R "$stats_source" "$stats_work/dependencies/"
done
swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete -disable-sandbox \
  -module-cache-path "$stats_work/module-cache" -I "$stats_work/dependencies" \
  -I "$stats_project/.build/checkouts/GRDB.swift/Sources/GRDBSQLite" \
  "$stats_project/scripts/library-statistics-smoke.swift" \
  "$stats_project/Sources/ShelfMac/Library/LibraryStatisticsModel.swift" \
  "$stats_project/Sources/ShelfMac/Localization/AppLanguage.swift" \
  "$stats_work/dependencies/libShelfCore.a" -lsqlite3 -o "$stats_work/LibraryStatisticsSmoke"
"$stats_work/LibraryStatisticsSmoke"
