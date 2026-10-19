#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
reader_work="$(mktemp -d "${TMPDIR:-/tmp}/shelf-reader-smoke.XXXXXX")"
trap 'rm -rf "$reader_work"' EXIT
python3 "$project_root/scripts/reader-fixtures.py" "$reader_work"
swiftc -parse-as-library -swift-version 6 -module-cache-path "$reader_work/module-cache" "$project_root/scripts/reader-smoke.swift" -o "$reader_work/ReaderSmoke"
for reader_format in epub mobi azw3; do
  reader_initial=""
  if [[ "$reader_format" != epub ]]; then reader_initial="mobi:0:500"; fi
  "$reader_work/ReaderSmoke" "$project_root/Sources/Audilse/Resources/Reader/reader.html" "$reader_work/fixture.$reader_format" "$reader_format" "$reader_initial" "$reader_work/location.txt"
  reader_saved="$(cat "$reader_work/location.txt")"
  # New OS process and a fresh non-persistent WKWebView restore the emitted location.
  "$reader_work/ReaderSmoke" "$project_root/Sources/Audilse/Resources/Reader/reader.html" "$reader_work/fixture.$reader_format" "$reader_format" "$reader_saved"
done
