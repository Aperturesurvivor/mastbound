#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL_LINK="$HOME/.local/bin/roaster-tool-fetch"
TOOL_TARGET="/Applications/Screen Time Roaster.app/Contents/Resources/RoasterToolFetch"
INSTALLER="$ROOT_DIR/dist/Screen Time Roaster.app/Contents/Resources/RoasterInstaller"
if [[ ! -x "$INSTALLER" ]]; then
  INSTALLER="/Applications/Screen Time Roaster.app/Contents/Resources/RoasterInstaller"
fi
INSTALLER_HASH="$(/usr/bin/shasum -a 256 "$INSTALLER" | /usr/bin/awk '{print $1}')"
if [[ ! "$INSTALLER_HASH" =~ ^[0-9a-f]{64}$ ]]; then
  echo "Could not bind administrator authorization to this exact installer." >&2
  exit 1
fi

/usr/bin/osascript - "$INSTALLER" "$INSTALLER_HASH" <<'APPLESCRIPT'
on run argv
    set installerPath to item 1 of argv
    set installerHash to item 2 of argv
    set privilegedScript to "set -eu; source_installer=$1; expected_hash=$2; shift 2; staging_dir=$(/usr/bin/mktemp -d /private/var/run/ScreenTimeRoaster.XXXXXX); staged_installer=\"$staging_dir/RoasterInstaller\"; cleanup() { /bin/rm -f \"$staged_installer\"; /bin/rmdir \"$staging_dir\"; }; trap cleanup EXIT HUP INT TERM; /usr/bin/install -o root -g wheel -m 0755 \"$source_installer\" \"$staged_installer\"; actual_hash=$(/usr/bin/shasum -a 256 \"$staged_installer\" | /usr/bin/awk '{print $1}'); [ \"$actual_hash\" = \"$expected_hash\" ] || { echo 'The installer changed after authorization was requested.' >&2; exit 74; }; \"$staged_installer\" \"$@\""
    set commandText to "/bin/sh -c " & quoted form of privilegedScript & " -- " & quoted form of installerPath & " " & quoted form of installerHash & " uninstall"
    return do shell script commandText with administrator privileges
end run
APPLESCRIPT

if [[ -L "$TOOL_LINK" && "$(/usr/bin/readlink "$TOOL_LINK")" == "$TOOL_TARGET" ]]; then
  /bin/rm "$TOOL_LINK"
fi
