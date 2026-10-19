#!/bin/bash
set -euo pipefail
year_review_project="$(cd "$(dirname "$0")/.." && pwd)"
year_review_prebuilt="${YEAR_REVIEW_SMOKE_PREBUILT:-$year_review_project/.build/debug}"
year_review_work="${YEAR_REVIEW_SMOKE_WORKDIR:-$(mktemp -d "${TMPDIR:-/tmp}/shelf-year-review-smoke.XXXXXX")}"
mkdir -p "$year_review_work/dependencies" "$year_review_work/images" "$year_review_work/sources"
for year_review_file in libAudilseCore.a AudilseCore.swiftmodule GRDB.swiftmodule SocketIO.swiftmodule Starscream.swiftmodule; do
  if [[ ! -e "$year_review_prebuilt/$year_review_file" ]]; then
    echo "Matching prebuilt Debug Core modules and archive are required; this script does not run a shared build." >&2
    exit 2
  fi
  cp -R "$year_review_prebuilt/$year_review_file" "$year_review_work/dependencies/"
done
for year_review_language in en zh-Hans; do
  cp -R "$year_review_project/Sources/Audilse/Resources/$year_review_language.lproj" "$year_review_work/"
done
year_review_sources=(
  Sources/Audilse/Localization/AppLanguage.swift
  Sources/Audilse/Design/Theme.swift
  Sources/Audilse/Features/YearReviewGallery.swift
  Sources/Audilse/Features/PersonalYearReviewView.swift
  Sources/Audilse/ServerAdmin/ServerStatisticsModel.swift
  Sources/Audilse/ServerAdmin/ServerStatisticsView.swift
  Sources/Audilse/ServerAdmin/ServerStatisticsReviewView.swift
  scripts/year-review-smoke.swift
)
for year_review_source in "${year_review_sources[@]}"; do
  cp "$year_review_project/$year_review_source" "$year_review_work/sources/$(basename "$year_review_source")"
done
python3 - "$year_review_project" "$year_review_work" "${year_review_sources[@]}" <<'PY'
import hashlib, json, pathlib, sys
project, work = map(pathlib.Path, sys.argv[1:3])
hashes = {}
for relative in sys.argv[3:]:
    original, copied = project / relative, work / 'sources' / pathlib.Path(relative).name
    a, b = original.read_bytes(), copied.read_bytes()
    if a != b:
        raise SystemExit('Product source changed while creating the smoke snapshot')
    hashes[relative] = hashlib.sha256(b).hexdigest()
(work / 'SourceHashes.json').write_text(json.dumps(hashes, indent=2, sort_keys=True) + '\n')
PY
swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete \
  -module-cache-path "$year_review_work/module-cache" \
  -I "$year_review_work/dependencies" \
  -I "$year_review_project/.build/checkouts/GRDB.swift/Sources/GRDBSQLite" \
  "$year_review_work/sources/AppLanguage.swift" \
  "$year_review_work/sources/Theme.swift" \
  "$year_review_work/sources/YearReviewGallery.swift" \
  "$year_review_work/sources/PersonalYearReviewView.swift" \
  "$year_review_work/sources/ServerStatisticsModel.swift" \
  "$year_review_work/sources/ServerStatisticsView.swift" \
  "$year_review_work/sources/ServerStatisticsReviewView.swift" \
  "$year_review_work/sources/year-review-smoke.swift" \
  "$year_review_work/dependencies/libAudilseCore.a" -lsqlite3 \
  -o "$year_review_work/YearReviewSmoke"
"$year_review_work/YearReviewSmoke" "$year_review_work/images" "$@"
python3 - "$year_review_project" "$year_review_work/SourceHashes.json" <<'PY'
import hashlib, json, pathlib, sys
project = pathlib.Path(sys.argv[1])
for relative, expected in json.loads(pathlib.Path(sys.argv[2]).read_text()).items():
    if hashlib.sha256((project / relative).read_bytes()).hexdigest() != expected:
        raise SystemExit('Product source changed after the verified render: ' + relative)
print('PASS year-review compiled source snapshot still matches the workspace')
PY
