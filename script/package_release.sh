#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: ./script/package_release.sh [options]

Build a universal release bundle and ZIP archive without installing or publishing it.

Required signing choice:
  --sign-identity NAME   Sign with this exact Developer ID Application identity.
  --unsigned             Build an unsigned local QA artifact instead.

Optional:
  --notary-profile NAME  Submit with this existing notarytool keychain profile,
                         wait for acceptance, and staple the app. This is the
                         only option that initiates a notarization request.
  --version VERSION      CFBundleShortVersionString (default: 1.0.0).
  --build-number NUMBER  CFBundleVersion (default: 1).
  -h, --help             Show this help.

Raw Apple credentials are intentionally unsupported. Store credentials in a
notarytool keychain profile first, then pass only its profile name explicitly.
EOF
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/dist/release"
APP_NAME="Mastbound"
APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"
ZIP_ARCHIVE="$OUTPUT_DIR/Mastbound.zip"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON_SOURCE="$ROOT_DIR/Assets/AppIcon.icns"
BUNDLE_ID="com.josiahwilson.ScreenTimeRoasterMac"
MIN_SYSTEM_VERSION="14.0"

SIGN_IDENTITY=""
NOTARY_PROFILE=""
RELEASE_VERSION="1.0.0"
BUILD_NUMBER="1"
BUILD_UNSIGNED=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sign-identity)
      [[ $# -ge 2 ]] || { echo "--sign-identity requires a value." >&2; exit 2; }
      SIGN_IDENTITY="$2"
      shift 2
      ;;
    --notary-profile)
      [[ $# -ge 2 ]] || { echo "--notary-profile requires a value." >&2; exit 2; }
      NOTARY_PROFILE="$2"
      shift 2
      ;;
    --version)
      [[ $# -ge 2 ]] || { echo "--version requires a value." >&2; exit 2; }
      RELEASE_VERSION="$2"
      shift 2
      ;;
    --build-number)
      [[ $# -ge 2 ]] || { echo "--build-number requires a value." >&2; exit 2; }
      BUILD_NUMBER="$2"
      shift 2
      ;;
    --unsigned)
      BUILD_UNSIGNED=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ $BUILD_UNSIGNED -eq 1 && -n "$SIGN_IDENTITY" ]]; then
  echo "Choose either --unsigned or --sign-identity, not both." >&2
  exit 2
fi
if [[ $BUILD_UNSIGNED -eq 0 && -z "$SIGN_IDENTITY" ]]; then
  echo "Pass an explicit --sign-identity or use --unsigned for local QA." >&2
  exit 2
fi
if [[ -n "$NOTARY_PROFILE" && $BUILD_UNSIGNED -eq 1 ]]; then
  echo "Notarization requires a signed build." >&2
  exit 2
fi
if [[ ! "$RELEASE_VERSION" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]]; then
  echo "Release version must contain three period-separated integers." >&2
  exit 2
fi
if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "Build number must be a positive integer." >&2
  exit 2
fi
if [[ ! -f "$APP_ICON_SOURCE" ]]; then
  echo "Missing app icon: $APP_ICON_SOURCE" >&2
  exit 1
fi

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

SWIFT_BIN="$(/usr/bin/xcrun --find swift)"

if [[ $BUILD_UNSIGNED -eq 0 ]]; then
  if ! /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
    | /usr/bin/grep -F -- "\"$SIGN_IDENTITY\"" >/dev/null; then
    echo "Signing identity is not available with its private key: $SIGN_IDENTITY" >&2
    exit 1
  fi
fi

cd "$ROOT_DIR"
BIN_DIR="$("$SWIFT_BIN" build -c release --arch arm64 --arch x86_64 --show-bin-path)"
"$SWIFT_BIN" build -c release --arch arm64 --arch x86_64

EXECUTABLES=(RoasterMac RoasterEnforcer RoasterBlocklist RoasterInstaller RoasterToolFetch)
for executable_name in "${EXECUTABLES[@]}"; do
  binary_file="$BIN_DIR/$executable_name"
  if [[ ! -x "$binary_file" ]]; then
    echo "Missing release executable: $binary_file" >&2
    exit 1
  fi
  binary_arches=" $(/usr/bin/lipo -archs "$binary_file") "
  for required_arch in arm64 x86_64; do
    if [[ "$binary_arches" != *" $required_arch "* ]]; then
      echo "$executable_name is missing required architecture $required_arch." >&2
      exit 1
    fi
  done
done

case "$OUTPUT_DIR" in
  "$ROOT_DIR"/dist/release) ;;
  *) echo "Refusing to replace unexpected output directory: $OUTPUT_DIR" >&2; exit 1 ;;
esac
/bin/rm -rf "$APP_BUNDLE"
/bin/rm -f "$ZIP_ARCHIVE"
/bin/mkdir -p "$APP_MACOS" "$APP_RESOURCES"
/bin/cp "$BIN_DIR/RoasterMac" "$APP_MACOS/RoasterMac"
/bin/cp "$BIN_DIR/RoasterEnforcer" "$APP_RESOURCES/RoasterEnforcer"
/bin/cp "$BIN_DIR/RoasterBlocklist" "$APP_RESOURCES/RoasterBlocklist"
/bin/cp "$BIN_DIR/RoasterInstaller" "$APP_RESOURCES/RoasterInstaller"
/bin/cp "$BIN_DIR/RoasterToolFetch" "$APP_RESOURCES/RoasterToolFetch"
/bin/cp "$APP_ICON_SOURCE" "$APP_RESOURCES/AppIcon.icns"
/bin/chmod 0755 "$APP_MACOS/RoasterMac" "$APP_RESOURCES/RoasterEnforcer" \
  "$APP_RESOURCES/RoasterBlocklist" "$APP_RESOURCES/RoasterInstaller" \
  "$APP_RESOURCES/RoasterToolFetch"

/usr/bin/python3 - "$INFO_PLIST" "$BUNDLE_ID" "$APP_NAME" "$MIN_SYSTEM_VERSION" \
  "$RELEASE_VERSION" "$BUILD_NUMBER" <<'PY'
import plistlib
import sys

destination, bundle_id, app_name, minimum, version, build_number = sys.argv[1:]
payload = {
    "CFBundleDevelopmentRegion": "en",
    "CFBundleExecutable": "RoasterMac",
    "CFBundleIdentifier": bundle_id,
    "CFBundleIconFile": "AppIcon",
    "CFBundleIconName": "AppIcon",
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": app_name,
    "CFBundleDisplayName": app_name,
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": version,
    "CFBundleVersion": build_number,
    "LSMinimumSystemVersion": minimum,
    "NSHighResolutionCapable": True,
    "NSPrincipalClass": "NSApplication",
}
with open(destination, "wb") as handle:
    plistlib.dump(payload, handle, fmt=plistlib.FMT_XML, sort_keys=True)
PY

if [[ $BUILD_UNSIGNED -eq 0 ]]; then
  for nested_binary in \
    "$APP_RESOURCES/RoasterEnforcer" \
    "$APP_RESOURCES/RoasterBlocklist" \
    "$APP_RESOURCES/RoasterInstaller" \
    "$APP_RESOURCES/RoasterToolFetch"; do
    /usr/bin/codesign --force --options runtime --timestamp \
      --sign "$SIGN_IDENTITY" "$nested_binary"
  done
  /usr/bin/codesign --force --options runtime --timestamp \
    --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
  /usr/bin/codesign --verify --deep --strict --verbose=4 "$APP_BUNDLE"
fi

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_ARCHIVE"

if [[ -n "$NOTARY_PROFILE" ]]; then
  /usr/bin/xcrun notarytool submit "$ZIP_ARCHIVE" \
    --keychain-profile "$NOTARY_PROFILE" --wait
  /usr/bin/xcrun stapler staple "$APP_BUNDLE"
  /usr/bin/xcrun stapler validate "$APP_BUNDLE"
  /usr/bin/codesign --verify --deep --strict --verbose=4 "$APP_BUNDLE"
  /usr/sbin/spctl -a -vv --type execute "$APP_BUNDLE"
  /bin/rm -f "$ZIP_ARCHIVE"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_ARCHIVE"
fi

if [[ $BUILD_UNSIGNED -eq 1 ]]; then
  echo "Built unsigned local QA artifact: $ZIP_ARCHIVE"
elif [[ -z "$NOTARY_PROFILE" ]]; then
  echo "Built and verified signed artifact: $ZIP_ARCHIVE"
  echo "It was not notarized because no --notary-profile was supplied."
else
  echo "Built, notarized, stapled, and Gatekeeper-verified artifact: $ZIP_ARCHIVE"
fi
