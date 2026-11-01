#!/bin/bash
# Small regression gate: no application downloads or persistent test installs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

# Command Line Tools alone have no XCTest; use an installed Xcode for these tests.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
(cd app && swift test)
uv run --with pyyaml python -m unittest discover -s scripts/tests -v
python3 -m unittest discover -s scripts -p test_dotnet_cache.py -v
python3 scripts/test-window-levels.py

# Prefer the engine bundled in the local app. WINMAC_HOME can select a candidate.
if [ -z "${WINMAC_HOME:-}" ] && [ -x "$ROOT/build/Virtual.app/Contents/Resources/Engine/runtime/bin/virtual" ]; then
    export WINMAC_HOME="$ROOT/build/Virtual.app/Contents/Resources/Engine"
fi
exec /bin/bash "$ROOT/scripts/smoke-test.sh"
