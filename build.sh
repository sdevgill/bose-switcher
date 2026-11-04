#!/bin/bash
# Builds Bose Switcher.app into ~/Applications
set -euo pipefail
cd "$(dirname "$0")"

app="$HOME/Applications/Bose Switcher.app"
mkdir -p "$(dirname "$app")"
cache=$(mktemp -d "$(dirname "$app")/.bose-build.XXXXXX")
trap 'rm -rf "$cache"' EXIT
staged="$cache/Bose Switcher.app"

mkdir -p "$staged/Contents/MacOS" "$staged/Contents/Resources"
cp Info.plist "$staged/Contents/"
cp icon/AppIcon.icns "$staged/Contents/Resources/"
swiftc -O -parse-as-library -target "$(uname -m)-apple-macosx27.0" -module-cache-path "$cache/modules" -o "$staged/Contents/MacOS/BoseSwitcher" *.swift
codesign --force --sign - "$staged"
codesign --verify --strict "$staged"
if [ -e "$app" ]; then mv "$app" "$cache/previous.app"; fi
if ! mv "$staged" "$app"; then
    if [ -e "$cache/previous.app" ]; then mv "$cache/previous.app" "$app"; fi
    exit 1
fi
echo "Built $app"
