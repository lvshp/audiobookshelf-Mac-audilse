#!/bin/bash
set -euo pipefail
statistics_project="$(cd "$(dirname "$0")/.." && pwd)"
statistics_prebuilt="${STATISTICS_SMOKE_PREBUILT:-$statistics_project/.build/debug}"
statistics_work="${STATISTICS_SMOKE_WORKDIR:-$(mktemp -d "${TMPDIR:-/tmp}/shelf-statistics-smoke.XXXXXX")}"
mkdir -p "$statistics_work/dependencies"
if [[ ! -f "$statistics_prebuilt/libAudilseCore.a" ]]; then
  echo "A matching Debug AudilseCore archive is required; this script does not run a shared build." >&2
  exit 2
fi
for statistics_file in libAudilseCore.a AudilseCore.swiftmodule GRDB.swiftmodule SocketIO.swiftmodule Starscream.swiftmodule; do
  cp -R "$statistics_prebuilt/$statistics_file" "$statistics_work/dependencies/"
done
swiftc -parse-as-library -swift-version 6 -disable-sandbox \
  -module-cache-path "$statistics_work/module-cache" \
  -I "$statistics_work/dependencies" \
  -I "$statistics_project/.build/checkouts/GRDB.swift/Sources/GRDBSQLite" \
  "$statistics_project/scripts/statistics-smoke.swift" "$statistics_project/Sources/Audilse/Features/FeatureBrowserModel.swift" \
  "$statistics_project/Sources/Audilse/Localization/AppLanguage.swift" "$statistics_work/dependencies/libAudilseCore.a" \
  -lsqlite3 -o "$statistics_work/StatisticsSmoke"
"$statistics_work/StatisticsSmoke"
