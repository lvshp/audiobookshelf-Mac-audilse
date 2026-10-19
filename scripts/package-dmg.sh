#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
APP_PATH="${1:-build/Audisle.app}"
OUTPUT_DIR="${2:-build/delivery}"
test -d "$APP_PATH"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ && "$BUILD" =~ ^[0-9]+$ ]]
test "$(lipo -archs "$APP_PATH/Contents/MacOS/ShelfMac")" = arm64
codesign --verify --deep --strict "$APP_PATH"
mkdir -p "$OUTPUT_DIR" "$PROJECT_DIR/build"
STAGE=$(mktemp -d "$PROJECT_DIR/build/dmg-stage.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP_PATH" "$STAGE/Audisle.app"
ln -s /Applications "$STAGE/Applications"
DMG="$OUTPUT_DIR/Audisle-${VERSION}-build${BUILD}-arm64.dmg"
hdiutil create -volname Audisle -srcfolder "$STAGE" -ov -format UDZO "$DMG"
hdiutil verify "$DMG"
shasum -a 256 "$DMG" > "$DMG.sha256"
cp LICENSE "$OUTPUT_DIR/LICENSE.txt"
cp Packaging/VLC_DISTRIBUTION.md Packaging/THIRD_PARTY_NOTICES.md "$OUTPUT_DIR/"
printf 'Audisle %s (build %s), Apple Silicon, macOS 14+.\nAd-hoc signed; not notarized.\nKeep the accompanying VLC dependency/source bundle when distributing.\n' "$VERSION" "$BUILD" > "$OUTPUT_DIR/README.txt"
