#!/usr/bin/env bash
set -euo pipefail

if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

MODE="${1:-run}"
APP_NAME="Screen Time Roaster Mac"
PROCESS_NAME="RoasterMac"
BUNDLE_ID="com.josiahwilson.ScreenTimeRoasterMac"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
INFO_PLIST="$APP_CONTENTS/Info.plist"

pkill -x "$PROCESS_NAME" >/dev/null 2>&1 || true

cd "$ROOT_DIR"
swift build
BUILD_DIR="$(swift build --show-bin-path)"

case "$APP_BUNDLE" in
  "$ROOT_DIR"/dist/*.app) ;;
  *) echo "Refusing to replace unexpected app path: $APP_BUNDLE" >&2; exit 1 ;;
esac
/bin/rm -rf "$APP_BUNDLE"
/bin/mkdir -p "$APP_MACOS" "$APP_RESOURCES"
/bin/cp "$BUILD_DIR/RoasterMac" "$APP_MACOS/RoasterMac"
/bin/cp "$BUILD_DIR/RoasterEnforcer" "$APP_RESOURCES/RoasterEnforcer"
/bin/cp "$BUILD_DIR/RoasterBlocklist" "$APP_RESOURCES/RoasterBlocklist"
/bin/cp "$BUILD_DIR/RoasterInstaller" "$APP_RESOURCES/RoasterInstaller"
/bin/chmod 0755 "$APP_MACOS/RoasterMac" "$APP_RESOURCES/RoasterEnforcer" \
  "$APP_RESOURCES/RoasterBlocklist" "$APP_RESOURCES/RoasterInstaller"

/usr/bin/python3 - "$INFO_PLIST" "$PROCESS_NAME" "$BUNDLE_ID" "$APP_NAME" "$MIN_SYSTEM_VERSION" <<'PY'
import plistlib
import sys

destination, executable, bundle_id, app_name, minimum = sys.argv[1:]
payload = {
    "CFBundleDevelopmentRegion": "en",
    "CFBundleExecutable": executable,
    "CFBundleIdentifier": bundle_id,
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": app_name,
    "CFBundleDisplayName": app_name,
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "1.0.0",
    "CFBundleVersion": "1",
    "LSMinimumSystemVersion": minimum,
    "NSHighResolutionCapable": True,
    "NSPrincipalClass": "NSApplication",
}
with open(destination, "wb") as handle:
    plistlib.dump(payload, handle, fmt=plistlib.FMT_XML, sort_keys=True)
PY

/usr/bin/codesign --force --sign - --timestamp=none "$APP_RESOURCES/RoasterEnforcer"
/usr/bin/codesign --force --sign - --timestamp=none "$APP_RESOURCES/RoasterBlocklist"
/usr/bin/codesign --force --sign - --timestamp=none "$APP_RESOURCES/RoasterInstaller"
/usr/bin/codesign --force --sign - --timestamp=none "$APP_BUNDLE"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    /usr/bin/lldb -- "$APP_MACOS/RoasterMac"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$PROCESS_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    /bin/sleep 2
    /usr/bin/pgrep -x "$PROCESS_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
