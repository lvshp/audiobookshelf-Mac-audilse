#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
APP_PATH="${1:-build/Audilse.app}"
OUTPUT_DIR="${2:-build/delivery}"
test -d "$APP_PATH"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ && "$BUILD" = 1 ]]
test "$(lipo -archs "$APP_PATH/Contents/MacOS/Audilse")" = arm64
codesign --verify --deep --strict "$APP_PATH"
mkdir -p "$OUTPUT_DIR" "$PROJECT_DIR/build"
STAGE=$(mktemp -d "$PROJECT_DIR/build/dmg-stage.XXXXXX")
MOUNT=$(mktemp -d /private/tmp/audilse-dmg-check.XXXXXX)
MOUNTED=0
cleanup() {
  if [[ "$MOUNTED" = 1 ]]; then
    hdiutil detach "$MOUNT" -quiet || { echo "Could not detach verification volume: $MOUNT" >&2; return 1; }
  fi
  rm -rf "$STAGE"
  rmdir "$MOUNT"
}
trap cleanup EXIT
ditto "$APP_PATH" "$STAGE/Audilse.app"
ln -s /Applications "$STAGE/Applications"
DMG="$OUTPUT_DIR/Audilse-${VERSION}-arm64.dmg"
hdiutil create -volname Audilse -srcfolder "$STAGE" -ov -format UDZO "$DMG"
hdiutil verify "$DMG"
hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$MOUNT" -quiet
MOUNTED=1
bash scripts/verify-app-resources.sh "$MOUNT/Audilse.app"
hdiutil detach "$MOUNT" -quiet
MOUNTED=0
shasum -a 256 "$DMG" > "$DMG.sha256"
cp LICENSE "$OUTPUT_DIR/LICENSE.txt"
cp Packaging/VLC_DISTRIBUTION.md Packaging/THIRD_PARTY_NOTICES.md "$OUTPUT_DIR/"
printf 'Audilse %s, Apple Silicon, macOS 14+.\nAd-hoc signed; not notarized.\nKeep the accompanying VLC dependency/source bundle when distributing.\n' "$VERSION" > "$OUTPUT_DIR/README.txt"
