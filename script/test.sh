#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# With full Xcode, swift test finds the Testing framework by itself.
# With only the Command Line Tools, add its framework and library paths.
DEVELOPER_DIR_PATH="$(/usr/bin/xcode-select -p)"
if [[ "$DEVELOPER_DIR_PATH" == "/Library/Developer/CommandLineTools" ]]; then
  FRAMEWORKS="$DEVELOPER_DIR_PATH/Library/Developer/Frameworks"
  LIBS="$DEVELOPER_DIR_PATH/Library/Developer/usr/lib"
  exec swift test \
    -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
    -Xlinker -F -Xlinker "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$LIBS" \
    "$@"
fi
exec swift test "$@"
