#!/bin/bash
set -euo pipefail
cover_project="$(cd "$(dirname "$0")/.." && pwd)"
cover_prebuilt="${COVER_SMOKE_PREBUILT:-$cover_project/.build/debug}"
cover_work="${COVER_SMOKE_WORKDIR:-$(mktemp -d "${TMPDIR:-/tmp}/shelf-cover-smoke.XXXXXX")}"
for cover_file in libAudilseCore.a AudilseCore.swiftmodule GRDB.swiftmodule SocketIO.swiftmodule Starscream.swiftmodule; do
  if [[ ! -e "$cover_prebuilt/$cover_file" ]]; then
    echo "Matching Debug Core archive/modules are required; this script does not run a shared build." >&2
    exit 2
  fi
done
mkdir -p "$cover_work"
cover_dependencies="$(mktemp -d "$cover_work/dependencies.XXXXXX")"
for cover_file in libAudilseCore.a AudilseCore.swiftmodule GRDB.swiftmodule SocketIO.swiftmodule Starscream.swiftmodule; do
  cp -R "$cover_prebuilt/$cover_file" "$cover_dependencies/"
done
swiftc -parse-as-library -swift-version 6 -disable-sandbox \
  -module-cache-path "$cover_work/module-cache" \
  -I "$cover_dependencies" \
  -I "$cover_project/.build/checkouts/GRDB.swift/Sources/GRDBSQLite" \
  "$cover_project/scripts/cover-source-smoke.swift" \
  "$cover_project/Sources/Audilse/Design/CoverSource.swift" \
  "$cover_dependencies/libAudilseCore.a" \
  -lsqlite3 -o "$cover_work/CoverSourceSmoke"
"$cover_work/CoverSourceSmoke" "$cover_work"
