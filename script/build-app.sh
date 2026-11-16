#!/usr/bin/env bash
# Builds the draft app bundles into dist/ (not installed, not published):
#
#   dist/Mastbound Demo.app  fake status, no password, changes nothing
#   dist/Mastbound.app       the real app: Start and Add time ask for the
#                            admin password and change this Mac
#
#   script/build-app.sh [--testing]
#
# --testing builds the helper tools with test limits (1 min minimum).
# Both bundles are ad-hoc signed only. Never copy the real one over the old
# /Applications/Mastbound.app (see docs/migration.md).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
cli_flags=()
for argument in "$@"; do
  case "$argument" in
    --testing) cli_flags+=(--testing) ;;
    *) echo "unknown option: $argument" >&2; exit 2 ;;
  esac
done

BUILD_DIR="$ROOT_DIR/.build/app"
swift build -c release --build-path "$BUILD_DIR" --product MastboundApp
APP_BIN="$(swift build -c release --build-path "$BUILD_DIR" --show-bin-path)/MastboundApp"
TOOLS="$(mktemp -d)"
trap '/bin/rm -rf "$TOOLS"' EXIT
script/build-cli.sh ${cli_flags[@]+"${cli_flags[@]}"} "$TOOLS/tools" >/dev/null
VERSION="$("$TOOLS/tools/mastboundctl" version | cut -d' ' -f1)"

make_bundle() { # make_bundle <name> <bundle id> <demo true|false>
  local app="$ROOT_DIR/dist/$1.app"
  /bin/rm -rf "$app"
  /bin/mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  /bin/cp "$APP_BIN" "$app/Contents/MacOS/Mastbound"
  /bin/cp "$TOOLS/tools/mastboundctl" "$TOOLS/tools/mastboundd" "$TOOLS/tools/adult-domains.txt" "$app/Contents/Resources/"
  /bin/cp -R "$ROOT_DIR/Resources/licenses" "$app/Contents/Resources/licenses"
  /bin/cp "$ROOT_DIR/ATTRIBUTIONS.md" "$ROOT_DIR/LICENSE" "$app/Contents/Resources/"
  /bin/cp "$ROOT_DIR/Assets/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
  /usr/bin/plutil -create xml1 "$app/Contents/Info.plist"
  local p="$app/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleName -string "$1" "$p"
  /usr/bin/plutil -insert CFBundleDisplayName -string "$1" "$p"
  /usr/bin/plutil -insert CFBundleIdentifier -string "$2" "$p"
  /usr/bin/plutil -insert CFBundleExecutable -string "Mastbound" "$p"
  /usr/bin/plutil -insert CFBundlePackageType -string "APPL" "$p"
  /usr/bin/plutil -insert CFBundleShortVersionString -string "$VERSION" "$p"
  /usr/bin/plutil -insert CFBundleVersion -string "1" "$p"
  /usr/bin/plutil -insert CFBundleIconFile -string "AppIcon" "$p"
  /usr/bin/plutil -insert LSMinimumSystemVersion -string "14.0" "$p"
  /usr/bin/plutil -insert NSHighResolutionCapable -bool true "$p"
  /usr/bin/plutil -insert MastboundDemo -bool "$3" "$p"
  /usr/bin/codesign --force --sign - "$app/Contents/Resources/mastboundctl" "$app/Contents/Resources/mastboundd"
  /usr/bin/codesign --force --sign - "$app"
  echo "built $app"
}

make_bundle "Mastbound Demo" "com.josiahwilson.mastbound.demo" true
make_bundle "Mastbound" "com.josiahwilson.mastbound.app" false
