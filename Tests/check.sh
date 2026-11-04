#!/bin/bash
# Compile the app and run checks that never open Bluetooth or start the app
set -euo pipefail
cd "$(dirname "$0")/.."
build_folder=$(mktemp -d "${TMPDIR%/}/bose-build.XXXXXX")
trap 'find "$build_folder" -depth -delete' EXIT
swiftc -O -parse-as-library -target "$(uname -m)-apple-macosx27.0" -module-cache-path "$build_folder/cache" -o "$build_folder/app" *.swift
swiftc -parse-as-library -target "$(uname -m)-apple-macosx27.0" -module-cache-path "$build_folder/cache" -o "$build_folder/checks" Bluetooth.swift DeviceState.swift Tests/BehaviorTests.swift
"$build_folder/checks"
plutil -lint Info.plist
bash -n build.sh
