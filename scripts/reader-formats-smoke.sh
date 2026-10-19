#!/bin/bash
set -euo pipefail
reader_project="$(cd "$(dirname "$0")/.." && pwd)"
reader_prebuilt="${READER_SMOKE_PREBUILT:-$reader_project/.build/debug}"
reader_work="${READER_FORMAT_WORKDIR:-$(mktemp -d "${TMPDIR:-/tmp}/shelf-reader-formats.XXXXXX")}"
mkdir -p "$reader_work/dependencies"
if [[ ! -f "$reader_prebuilt/libAudilseCore.a" ]]; then
  echo "A matching Debug AudilseCore archive is required; this script does not run a shared build." >&2
  exit 2
fi
for reader_file in libAudilseCore.a AudilseCore.swiftmodule GRDB.swiftmodule SocketIO.swiftmodule Starscream.swiftmodule; do
  cp -R "$reader_prebuilt/$reader_file" "$reader_work/dependencies/"
done
swiftc -parse-as-library -swift-version 6 -disable-sandbox \
  -module-cache-path "$reader_work/module-cache" \
  -I "$reader_work/dependencies" \
  -I "$reader_project/.build/checkouts/GRDB.swift/Sources/GRDBSQLite" \
  "$reader_project/scripts/reader-formats-smoke.swift" "$reader_project/Sources/Audilse/Reading/ReaderModel.swift" \
  "$reader_project/Sources/Audilse/Localization/AppLanguage.swift" "$reader_work/dependencies/libAudilseCore.a" \
  -lsqlite3 -o "$reader_work/ReaderFormatsSmoke"
echo "Isolated reader executable: $reader_work/ReaderFormatsSmoke"
if [[ "${1:-}" == --compile-only ]]; then exit 0; fi
python3 "$reader_project/scripts/reader-fixtures.py" "$reader_work/generated"
"$reader_work/ReaderFormatsSmoke" parse "$reader_work"
if [[ "${1:-}" != --live ]]; then exit 0; fi
python3 "$reader_project/scripts/reader-server-fixtures.py" "$reader_work"
"$reader_work/ReaderFormatsSmoke" download "$reader_work"
# Only this test process loses network access. The user's application is untouched.
/usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' "$reader_work/ReaderFormatsSmoke" offline "$reader_work"
"$reader_work/ReaderFormatsSmoke" sync "$reader_work"
