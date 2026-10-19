#!/bin/bash
set -euo pipefail
library_project="$(cd "$(dirname "$0")/.." && pwd)"
library_prebuilt="${LIBRARY_BROWSER_SMOKE_PREBUILT:-$library_project/.build/debug}"
library_work="${LIBRARY_BROWSER_SMOKE_WORKDIR:-$(mktemp -d "${TMPDIR:-/tmp}/shelf-library-browser-smoke.XXXXXX")}"
for library_file in libAudilseCore.a AudilseCore.swiftmodule GRDB.swiftmodule SocketIO.swiftmodule Starscream.swiftmodule; do
  if [[ ! -e "$library_prebuilt/$library_file" ]]; then
    echo "Matching Debug Core archive/modules are required; this script does not run a shared build." >&2
    exit 2
  fi
done
mkdir -p "$library_work"
library_dependencies="$(mktemp -d "$library_work/dependencies.XXXXXX")"
for library_file in libAudilseCore.a AudilseCore.swiftmodule GRDB.swiftmodule SocketIO.swiftmodule Starscream.swiftmodule; do
  cp -R "$library_prebuilt/$library_file" "$library_dependencies/"
done
swiftc -parse-as-library -swift-version 6 -disable-sandbox \
  -module-cache-path "$library_work/module-cache" \
  -I "$library_dependencies" \
  -I "$library_project/.build/checkouts/GRDB.swift/Sources/GRDBSQLite" \
  "$library_project/scripts/library-browser-smoke.swift" \
  "$library_project/Sources/Audilse/Library/LibraryBrowserModel.swift" \
  "$library_project/Sources/Audilse/Design/CoverSource.swift" \
  "$library_project/Sources/Audilse/Localization/AppLanguage.swift" \
  "$library_dependencies/libAudilseCore.a" \
  -lsqlite3 -o "$library_work/LibraryBrowserSmoke"
"$library_work/LibraryBrowserSmoke" "$library_work"
