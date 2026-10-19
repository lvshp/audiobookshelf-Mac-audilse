#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE="$PROJECT_DIR/Vendor/VLCKit.xcframework"
LOCK="$PROJECT_DIR/Packaging/VLC/patched-lock.json"
if /usr/bin/python3 -I "$PROJECT_DIR/scripts/verify-patched-vlc.py" --package "$PACKAGE" --lock "$LOCK"; then
  exit 0
fi
cat >&2 <<'INSTRUCTIONS'
ShelfMac requires the verified copy-drain VLCKit candidate. The existing framework is missing or does not match; no official-binary download fallback is permitted.
From the project root, verify and import the delivered candidate:
  /usr/bin/python3 -I scripts/import-patched-vlc.py --source build/vlc-source-delivery/exclusion-candidate-20261015/VLCKit.xcframework
  /usr/bin/python3 -I scripts/import-patched-vlc.py --source build/vlc-source-delivery/exclusion-candidate-20261015/VLCKit.xcframework --apply
The explicit --apply operation verifies a staged copy and preserves the old directory as a backup.
For an offline source rebuild, see Packaging/VLC/portable/README.md and build/vlc-source-delivery/README.md. A newly rebuilt binary can differ: review and update the patched lock before importing a different build; do not bypass verification.
INSTRUCTIONS
exit 1
