#!/bin/bash
# Run with bash icon/generate.sh, optionally passing a PNG preview destination
set -euo pipefail
cd "$(dirname "$0")"
work_folder=$(mktemp -d "${TMPDIR%/}/bose-icon.XXXXXX")
trap 'find "$work_folder" -depth -delete' EXIT
mkdir "$work_folder/AppIcon.iconset"
swift -module-cache-path "$work_folder/modules" Render.swift AppIcon.svg "$work_folder/master.png"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$work_folder/master.png" --out "$work_folder/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    doubled=$((size * 2))
    sips -z "$doubled" "$doubled" "$work_folder/master.png" --out "$work_folder/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$work_folder/AppIcon.iconset" -o AppIcon.icns
if [ "$#" -gt 0 ]; then cp "$work_folder/master.png" "$1"; fi
