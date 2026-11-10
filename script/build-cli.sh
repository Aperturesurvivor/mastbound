#!/usr/bin/env bash
# Builds mastboundd, mastboundctl and the list into one folder that
# `mastboundctl install` can install from.
#
#   script/build-cli.sh [--testing] [--upgrade-mark] [OUTPUT_DIR]
#
# --testing       short durations (1 min minimum, 2 min recovery). Never ship.
# --upgrade-mark  changes the version string, for the upgrade check.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
flags=()
OUTPUT_DIR="$ROOT_DIR/dist/mastbound"
for argument in "$@"; do
  case "$argument" in
    --testing) flags+=(-Xswiftc -DMASTBOUND_TESTING) ;;
    --upgrade-mark) flags+=(-Xswiftc -DMASTBOUND_UPGRADE_MARK) ;;
    -*) echo "unknown option: $argument" >&2; exit 2 ;;
    *) OUTPUT_DIR="$argument" ;;
  esac
done

cd "$ROOT_DIR"
# A separate build folder per flag set, so a test build never reuses
# objects from a release build or the other way round.
BUILD_DIR="$ROOT_DIR/.build/cli-$(printf '%s' "${flags[*]:-release}" | /usr/bin/shasum | cut -c1-8)"
swift build -c release --build-path "$BUILD_DIR" --product mastboundd ${flags[@]+"${flags[@]}"}
swift build -c release --build-path "$BUILD_DIR" --product mastboundctl ${flags[@]+"${flags[@]}"}
BIN_DIR="$(swift build -c release --build-path "$BUILD_DIR" --show-bin-path)"

/bin/rm -rf "$OUTPUT_DIR"
/bin/mkdir -p "$OUTPUT_DIR"
/bin/cp "$BIN_DIR/mastboundd" "$BIN_DIR/mastboundctl" "$OUTPUT_DIR/"
/bin/cp "$ROOT_DIR/Resources/adult-domains.txt" "$OUTPUT_DIR/"
"$OUTPUT_DIR/mastboundctl" version
