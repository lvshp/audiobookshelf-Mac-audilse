#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$PROJECT_DIR/scripts/vlc-source-kit.py" "$@"
