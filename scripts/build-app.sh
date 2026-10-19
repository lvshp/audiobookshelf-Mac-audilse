#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
CONFIGURATION="${CONFIGURATION:-release}"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/swift-cache"
bash scripts/prepare-vlc.sh
swift build --disable-sandbox -c "$CONFIGURATION" --product Audilse --cache-path .build/package-cache
BIN_DIR="$(swift build --disable-sandbox -c "$CONFIGURATION" --show-bin-path --cache-path .build/package-cache)"
# A separate output lets packaging finish without replacing a running app.
APP_PATH="${AUDILSE_APP_PATH:-$PROJECT_DIR/build/Audilse.app}"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" "$APP_PATH/Contents/Frameworks"
cp "$BIN_DIR/Audilse" "$APP_PATH/Contents/MacOS/Audilse"
cp Packaging/Info.plist "$APP_PATH/Contents/Info.plist"
ditto Packaging/Licenses "$APP_PATH/Contents/Resources/Licenses"
cp LICENSE "$APP_PATH/Contents/Resources/Audilse-LICENSE.txt"
cp Packaging/THIRD_PARTY_NOTICES.md "$APP_PATH/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp Packaging/VLC_DISTRIBUTION.md "$APP_PATH/Contents/Resources/VLC_DISTRIBUTION.md"
if [[ -d "$BIN_DIR/Audilse_Audilse.bundle" ]]; then
  ditto "$BIN_DIR/Audilse_Audilse.bundle" "$APP_PATH/Contents/Resources/Audilse_Audilse.bundle"
fi
for LANGUAGE in en zh-Hans; do
  ditto "Sources/Audilse/Resources/$LANGUAGE.lproj" "$APP_PATH/Contents/Resources/$LANGUAGE.lproj"
done
if [[ -f Packaging/AppIcon.icns ]]; then
  cp Packaging/AppIcon.icns "$APP_PATH/Contents/Resources/AppIcon.icns"
fi
VLC_FRAMEWORK="$PROJECT_DIR/Vendor/VLCKit.xcframework/macos-arm64_x86_64/VLCKit.framework"
if [[ -n "$VLC_FRAMEWORK" ]]; then
  ditto "$VLC_FRAMEWORK" "$APP_PATH/Contents/Frameworks/VLCKit.framework"
  while IFS= read -r -d '' LIBRARY_PATH; do
    codesign --force --sign - --timestamp=none "$LIBRARY_PATH" 2>/dev/null
  done < <(find "$APP_PATH/Contents/Frameworks/VLCKit.framework" -type f -name '*.dylib' -print0)
  codesign --force --sign - --timestamp=none "$APP_PATH/Contents/Frameworks/VLCKit.framework"
fi
codesign --force --sign - --timestamp=none "$APP_PATH"
echo "$APP_PATH"
