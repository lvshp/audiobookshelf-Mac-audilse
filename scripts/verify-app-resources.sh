#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
APP_PATH="${1:?Usage: verify-app-resources.sh /path/to/Audilse.app}"
test -d "$APP_PATH"
CHECK_ROOT=$(mktemp -d /private/tmp/audilse-resource-check.XXXXXX)
trap 'rm -rf "$CHECK_ROOT"' EXIT
CHECK_APP="$CHECK_ROOT/Audilse.app"
ditto "$APP_PATH" "$CHECK_APP"
codesign --verify --deep --strict "$CHECK_APP"
cd "$CHECK_ROOT"
# Only the child is sandboxed: copying the app above must be able to read it.
# A new location and denied source tree expose accidental development fallbacks.
/usr/bin/python3 -I - "$PROJECT_DIR" "$CHECK_APP" <<'PY'
import os
from pathlib import Path
import subprocess
import sys

project, app = sys.argv[1:]
profile = '(version 1)(allow default)(deny file-read* (subpath (param "PROJECT")) (subpath (param "BUILD")))'
command = ['/usr/bin/sandbox-exec', '-D', 'PROJECT=' + project,
           '-D', 'BUILD=' + str(Path(project) / '.build'), '-p', profile,
           str(Path(app) / 'Contents/MacOS/Audilse'), '--verify-resources']
environment = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': os.environ['HOME'],
               'TMPDIR': str(Path(app).parent)}
try:
    subprocess.run(command, env=environment, check=True, timeout=30)
except subprocess.TimeoutExpired:
    raise SystemExit('Resource verification timed out; the app must exit without launching its UI.')
PY
