#!/usr/bin/env bash
# Builds the release DMG: Developer ID signed, hardened runtime, notarized
# and stapled.
#
#   script/release.sh [--no-notarize]
#
# Needs the "Developer ID Application" certificate in the login keychain and
# a notarytool profile named "mastbound", made once with:
#
#   xcrun notarytool store-credentials mastbound \
#     --apple-id <apple id> --team-id TXWB2TUKP2
#
# Output: dist/Mastbound-<version>.dmg. Never built with --testing.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
NOTARIZE=1
for argument in "$@"; do
  case "$argument" in
    --no-notarize) NOTARIZE=0 ;;
    *) echo "unknown option: $argument" >&2; exit 2 ;;
  esac
done

IDENTITY="${IDENTITY:-Developer ID Application: Josiah Wilson (TXWB2TUKP2)}"
PROFILE="${PROFILE:-mastbound}"

script/test.sh >/dev/null
script/check-safesearch.sh || { echo "refusing: a SafeSearch address no longer filters (see Sources/MastboundCore/SafeSearch.swift)" >&2; exit 1; }
script/build-app.sh >/dev/null
APP="$ROOT_DIR/dist/Mastbound.app"
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
if "$APP/Contents/Resources/mastboundctl" version | grep -qi test; then
  echo "refusing: this is a test build" >&2; exit 1
fi

sign() { /usr/bin/codesign --force --options runtime --timestamp --sign "$IDENTITY" "$@"; }
sign --identifier com.josiahwilson.mastbound.ctl "$APP/Contents/Resources/mastboundctl"
sign --identifier com.josiahwilson.mastbound.daemon "$APP/Contents/Resources/mastboundd"
sign "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"

STAGE="$(mktemp -d)"
trap '/bin/rm -rf "$STAGE"' EXIT
/usr/bin/ditto "$APP" "$STAGE/Mastbound.app"
/bin/ln -s /Applications "$STAGE/Applications"
DMG="$ROOT_DIR/dist/Mastbound-$VERSION.dmg"
/bin/rm -f "$DMG"
/usr/bin/hdiutil create -quiet -volname "Mastbound" -srcfolder "$STAGE" -fs APFS -format UDZO "$DMG"
sign "$DMG"

if [[ "$NOTARIZE" == 1 ]]; then
  /usr/bin/xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  /usr/bin/xcrun stapler staple "$DMG"
  /usr/bin/xcrun stapler validate "$DMG"
  /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi
/usr/bin/shasum -a 256 "$DMG"
echo "built $DMG"
