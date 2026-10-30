#!/bin/bash
set -euo pipefail
UPDATE_TEST_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPDATE_PROJECT_DIRECTORY="${UPDATE_TEST_DIRECTORY%/Tests}"
UPDATE_TEST_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/gpu-z-updater-tests.XXXXXX")"
trap 'rm -rf "$UPDATE_TEST_TEMP"' EXIT
swiftc -Onone -warnings-as-errors -swift-version 5 -target "$(uname -m)-apple-macos11.0" \
  "$UPDATE_PROJECT_DIRECTORY/Sources/AppUpdateCore.swift" \
  "$UPDATE_PROJECT_DIRECTORY/Sources/AppUpdateInstaller.swift" \
  "$UPDATE_PROJECT_DIRECTORY/Sources/AppUpdater.swift" \
  "$UPDATE_TEST_DIRECTORY/AppUpdateTests.swift" \
  -o "$UPDATE_TEST_TEMP/update-tests" -framework Foundation -framework AppKit -framework CryptoKit
"$UPDATE_TEST_TEMP/update-tests"
