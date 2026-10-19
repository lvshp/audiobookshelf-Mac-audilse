#!/bin/bash
set -euo pipefail
compat_project="$(cd "$(dirname "$0")/.." && pwd)"
compat_prebuilt="${COMPAT_SMOKE_PREBUILT:-$compat_project/.build/debug}"
compat_work="${COMPAT_SMOKE_WORKDIR:-$(mktemp -d "${TMPDIR:-/tmp}/shelf-compat-smoke.XXXXXX")}"
mkdir -p "$compat_work/dependencies"
if [[ ! -f "$compat_prebuilt/libShelfCore.a" ]]; then
  echo "A matching Debug ShelfCore archive is required; build it before running this opt-in smoke." >&2
  exit 2
fi
# Copy the matching archive and modules before independent compilation. No shared build lock.
for compat_file in libShelfCore.a ShelfCore.swiftmodule GRDB.swiftmodule SocketIO.swiftmodule Starscream.swiftmodule; do
  cp -R "$compat_prebuilt/$compat_file" "$compat_work/dependencies/"
done
swiftc -parse-as-library -swift-version 6 -disable-sandbox \
  -module-cache-path "$compat_work/module-cache" \
  -I "$compat_work/dependencies" \
  -I "$compat_project/.build/checkouts/GRDB.swift/Sources/GRDBSQLite" \
  "$compat_project/scripts/compatibility-smoke.swift" "$compat_work/dependencies/libShelfCore.a" \
  -lsqlite3 -o "$compat_work/CompatibilitySmoke"
echo "Isolated smoke executable: $compat_work/CompatibilitySmoke"
if [[ "${1:-}" == "--compile-only" ]]; then exit 0; fi
"$compat_work/CompatibilitySmoke" "$@"
