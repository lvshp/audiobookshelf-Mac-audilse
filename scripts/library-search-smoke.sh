#!/bin/bash
set -euo pipefail
search_project="$(cd "$(dirname "$0")/.." && pwd)"
search_prebuilt="${LIBRARY_SEARCH_SMOKE_PREBUILT:-$search_project/.build/debug}"
search_work="${LIBRARY_SEARCH_SMOKE_WORKDIR:-$(mktemp -d "${TMPDIR:-/tmp}/shelf-library-search-smoke.XXXXXX")}"
for search_file in libShelfCore.a ShelfCore.swiftmodule GRDB.swiftmodule SocketIO.swiftmodule Starscream.swiftmodule; do
  if [[ ! -e "$search_prebuilt/$search_file" ]]; then
    echo "Matching Debug Core archive/modules are required; this script does not run a shared build." >&2
    exit 2
  fi
done
mkdir -p "$search_work"
search_dependencies="$(mktemp -d "$search_work/dependencies.XXXXXX")"
for search_file in libShelfCore.a ShelfCore.swiftmodule GRDB.swiftmodule SocketIO.swiftmodule Starscream.swiftmodule; do
  cp -R "$search_prebuilt/$search_file" "$search_dependencies/"
done
swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete -disable-sandbox \
  -module-cache-path "$search_work/module-cache" -I "$search_dependencies" \
  -I "$search_project/.build/checkouts/GRDB.swift/Sources/GRDBSQLite" \
  "$search_project/scripts/library-search-smoke.swift" \
  "$search_project/Sources/ShelfMac/Search/LibrarySearchModel.swift" \
  "$search_project/Sources/ShelfMac/Design/CoverSource.swift" \
  "$search_project/Sources/ShelfMac/Localization/AppLanguage.swift" \
  "$search_dependencies/libShelfCore.a" -lsqlite3 -o "$search_work/LibrarySearchSmoke"
"$search_work/LibrarySearchSmoke" "$search_work"
