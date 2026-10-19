#!/usr/bin/env bash
set -euo pipefail

DEVELOPER_ROOT="/Applications/Xcode.app/Contents/Developer"
if [[ ! -x "$DEVELOPER_ROOT/usr/bin/xcodebuild" ]]; then
  echo "Full Xcode with the macOS SDK is required. Restore Xcode.app in /Applications, launch it once to finish installing components, then retry." >&2
  exit 1
fi
export DEVELOPER_DIR="$DEVELOPER_ROOT"
if ! /usr/bin/xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1; then
  echo "Full Xcode with the macOS SDK is required. Restore Xcode.app in /Applications, launch it once to finish installing components, then retry." >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
swift test
