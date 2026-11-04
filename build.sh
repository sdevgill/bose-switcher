#!/bin/bash
# Builds Bose Switcher.app into ~/Applications
set -euo pipefail
cd "$(dirname "$0")"

app="$HOME/Applications/Bose Switcher.app"
cache=$(mktemp -d)
trap 'rm -rf "$cache"' EXIT

mkdir -p "$app/Contents/MacOS"
cp Info.plist "$app/Contents/"
swiftc -O -parse-as-library -target "$(uname -m)-apple-macosx27.0" -module-cache-path "$cache" -o "$app/Contents/MacOS/BoseSwitcher" *.swift
codesign --force --sign - "$app"
echo "Built $app"
