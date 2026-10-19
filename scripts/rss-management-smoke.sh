#!/bin/bash
set -euo pipefail
rss_project="$(cd "$(dirname "$0")/.." && pwd)"
rss_prebuilt="${RSS_MANAGEMENT_SMOKE_PREBUILT:-$rss_project/.build/debug}"
rss_work="${RSS_MANAGEMENT_SMOKE_WORKDIR:-$(mktemp -d "${TMPDIR:-/tmp}/shelf-rss-management-smoke.XXXXXX")}"
mkdir -p "$rss_work/dependencies"
for rss_file in libAudilseCore.a AudilseCore.swiftmodule GRDB.swiftmodule SocketIO.swiftmodule Starscream.swiftmodule; do
  rss_source="$rss_prebuilt/$rss_file"
  if [[ ! -e "$rss_source" && -e "$rss_prebuilt/dependencies/$rss_file" ]]; then rss_source="$rss_prebuilt/dependencies/$rss_file"; fi
  if [[ ! -e "$rss_source" ]]; then echo "Matching Core archive/modules required; no shared build is run." >&2; exit 2; fi
  cp -R "$rss_source" "$rss_work/dependencies/"
done
swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete -disable-sandbox \
  -module-cache-path "$rss_work/module-cache" -I "$rss_work/dependencies" \
  -I "$rss_project/.build/checkouts/GRDB.swift/Sources/GRDBSQLite" \
  "$rss_project/scripts/rss-management-smoke.swift" \
  "$rss_project/Sources/Audilse/Personal/RSSManagementModel.swift" \
  "$rss_project/Sources/Audilse/Personal/PersonalAccountScope.swift" \
  "$rss_project/Sources/Audilse/Localization/AppLanguage.swift" \
  "$rss_work/dependencies/libAudilseCore.a" -lsqlite3 -o "$rss_work/RSSManagementSmoke"
"$rss_work/RSSManagementSmoke"
