#!/bin/bash
# Compile the app and run checks that never open Bluetooth or start the app
set -euo pipefail
cd "$(dirname "$0")/.."
build_folder=$(mktemp -d "${TMPDIR%/}/bose-build.XXXXXX")
trap 'find "$build_folder" -depth -delete' EXIT
swiftc -O -parse-as-library -target "$(uname -m)-apple-macosx27.0" -module-cache-path "$build_folder/cache" -o "$build_folder/app" *.swift
swiftc -parse-as-library -target "$(uname -m)-apple-macosx27.0" -module-cache-path "$build_folder/cache" -o "$build_folder/checks" Bluetooth.swift DeviceState.swift PanelPlacement.swift Tests/BehaviorTests.swift
"$build_folder/checks"
# Exercise the actual coordinator without starting the application or opening Bluetooth
sed -e 's/private //g' -e '/^@main$/d' main.swift > "$build_folder/Coordinator.swift"
swiftc -parse-as-library -target "$(uname -m)-apple-macosx27.0" -module-cache-path "$build_folder/cache" -o "$build_folder/coordinator-checks" Bluetooth.swift DeviceState.swift PanelPlacement.swift Panel.swift "$build_folder/Coordinator.swift" Tests/CoordinatorTests.swift
"$build_folder/coordinator-checks"
plutil -lint Info.plist
bash -n build.sh
