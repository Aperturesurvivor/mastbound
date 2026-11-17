#!/usr/bin/env bash
# Rebuilds Resources/adult-domains.txt and Sources/MastboundCore/BundledList.swift
# from a pinned StevenBlack/hosts revision. Changing REVISION needs a review
# of the list difference before it is committed.
set -euo pipefail

REVISION="92a38fd106abe49f50ed6904ff0e867f4eb44f9f"
SOURCES=(bigdargon sinfonietta-snuff sinfonietta tiuxo)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf "$WORK_DIR"' EXIT

files=()
for source in "${SOURCES[@]}"; do
  url="https://raw.githubusercontent.com/StevenBlack/hosts/$REVISION/extensions/porn/$source/hosts"
  /usr/bin/curl --fail --silent --show-error --proto '=https' --max-filesize 8388608 \
    --output "$WORK_DIR/$source.hosts" "$url"
  files+=("$WORK_DIR/$source.hosts")
done

cd "$ROOT_DIR"
swift run --quiet make-list Resources/adult-domains.txt Sources/MastboundCore/BundledList.swift "${files[@]}"
