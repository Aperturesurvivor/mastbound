#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/Screen Time Roaster.app"
INSTALLER="$APP_BUNDLE/Contents/Resources/RoasterInstaller"
TOOL_LINK="$HOME/.local/bin/roaster-tool-fetch"
TOOL_TARGET="/Applications/Screen Time Roaster.app/Contents/Resources/RoasterToolFetch"

if [[ ! -x "$INSTALLER" ]]; then
  "$ROOT_DIR/script/build_and_run.sh" --verify
fi

INSTALLER_HASH="$(/usr/bin/shasum -a 256 "$INSTALLER" | /usr/bin/awk '{print $1}')"
BUNDLE_CDHASH="$(/usr/bin/codesign -d --verbose=4 "$APP_BUNDLE" 2>&1 | /usr/bin/awk -F= '/^CDHash=[0-9A-Fa-f]+$/ {print tolower($2)}')"
if [[ ! "$INSTALLER_HASH" =~ ^[0-9a-f]{64}$ || ! "$BUNDLE_CDHASH" =~ ^[0-9a-f]{40,64}$ ]]; then
  echo "Could not bind administrator authorization to this exact build." >&2
  exit 1
fi

/usr/bin/osascript - "$INSTALLER" "$INSTALLER_HASH" "$APP_BUNDLE" "$BUNDLE_CDHASH" "$HOME" "$(/usr/bin/id -u)" <<'APPLESCRIPT'
on run argv
    set installerPath to item 1 of argv
    set installerHash to item 2 of argv
    set appBundlePath to item 3 of argv
    set bundleCDHash to item 4 of argv
    set userHomePath to item 5 of argv
    set userID to item 6 of argv
    set privilegedScript to "set -eu; source_installer=$1; expected_hash=$2; shift 2; staging_dir=$(/usr/bin/mktemp -d /private/var/run/ScreenTimeRoaster.XXXXXX); staged_installer=\"$staging_dir/RoasterInstaller\"; cleanup() { /bin/rm -f \"$staged_installer\"; /bin/rmdir \"$staging_dir\"; }; trap cleanup EXIT HUP INT TERM; /usr/bin/install -o root -g wheel -m 0755 \"$source_installer\" \"$staged_installer\"; actual_hash=$(/usr/bin/shasum -a 256 \"$staged_installer\" | /usr/bin/awk '{print $1}'); [ \"$actual_hash\" = \"$expected_hash\" ] || { echo 'The installer changed after authorization was requested.' >&2; exit 74; }; \"$staged_installer\" \"$@\""
    set commandText to "/bin/sh -c " & quoted form of privilegedScript & " -- " & quoted form of installerPath & " " & quoted form of installerHash & " install --app-bundle " & quoted form of appBundlePath & " --user-home " & quoted form of userHomePath & " --uid " & quoted form of userID & " --expected-bundle-cdhash " & quoted form of bundleCDHash
    return do shell script commandText with administrator privileges
end run
APPLESCRIPT

if [[ -L "$TOOL_LINK" || ! -e "$TOOL_LINK" ]]; then
  /bin/mkdir -p "$HOME/.local/bin"
  /bin/ln -sfn "$TOOL_TARGET" "$TOOL_LINK"
else
  echo "Installed the app, but preserved the existing non-symlink at $TOOL_LINK." >&2
fi
