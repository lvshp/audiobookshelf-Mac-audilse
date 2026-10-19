#!/bin/bash
set -euo pipefail
localization_project="$(cd "$(dirname "$0")/.." && pwd)"
localization_toolchain="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host"
localization_work="${LOCALIZATION_WORKDIR:-$(mktemp -d "${TMPDIR:-/tmp}/shelf-localization.XXXXXX")}"
mkdir -p "$localization_work"
swiftc -parse-as-library -swift-version 6 \
  -module-cache-path "$localization_work/module-cache" \
  -I "$localization_toolchain" -L "$localization_toolchain" \
  -Xlinker -rpath -Xlinker "$localization_toolchain" \
  "$localization_project/scripts/localize-sources.swift" -o "$localization_work/LocalizeSources"
"$localization_work/LocalizeSources" "${1:-inventory}" "$localization_project" "${2:-$localization_work/inventory.json}"
