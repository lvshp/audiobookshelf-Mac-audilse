#!/bin/bash
set -euo pipefail
home_project="$(cd "$(dirname "$0")/.." && pwd)"
home_prebuilt="${HOME_SMOKE_PREBUILT:-$home_project/.build/debug}"
home_work="${HOME_SMOKE_WORKDIR:-$(mktemp -d "${TMPDIR:-/tmp}/shelf-home-smoke.XXXXXX")}"
for home_file in libAudilseCore.a AudilseCore.swiftmodule GRDB.swiftmodule SocketIO.swiftmodule Starscream.swiftmodule; do
  if [[ ! -e "$home_prebuilt/$home_file" ]]; then
    echo "Matching Debug Core archive/modules are required; this script does not run a shared build." >&2
    exit 2
  fi
done
mkdir -p "$home_work"
home_dependencies="$(mktemp -d "$home_work/dependencies.XXXXXX")"
for home_file in libAudilseCore.a AudilseCore.swiftmodule GRDB.swiftmodule SocketIO.swiftmodule Starscream.swiftmodule; do
  cp -R "$home_prebuilt/$home_file" "$home_dependencies/"
done
swiftc -parse-as-library -swift-version 6 -disable-sandbox \
  -module-cache-path "$home_work/module-cache" \
  -I "$home_dependencies" \
  -I "$home_project/.build/checkouts/GRDB.swift/Sources/GRDBSQLite" \
  "$home_project/scripts/home-smoke.swift" \
  "$home_project/Sources/Audilse/Home/HomeModel.swift" \
  "$home_project/Sources/Audilse/Localization/AppLanguage.swift" \
  "$home_dependencies/libAudilseCore.a" \
  -lsqlite3 -o "$home_work/HomeSmoke"
"$home_work/HomeSmoke" "$home_work"
